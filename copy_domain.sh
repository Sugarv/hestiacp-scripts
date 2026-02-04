#!/bin/bash
# Copies a WordPress site from one domain to another

# --- CONFIGURATION & CHECKS ---

export PATH=$PATH:/usr/local/hestia/bin

# Check for Hestia
if ! command -v v-add-web-domain &> /dev/null; then
    echo "❌ Error: HestiaCP commands not found."
    exit 1
fi
# Ensure script is run with necessary arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <user> <source-domain> <destination-domain>"
    exit 1
fi
# Input arguments
USER="$1"
SOURCE_DOMAIN="$2"
DESTINATION_DOMAIN="$3"

DOMAIN_DIR="/home/${USER}/web"
SOURCE_ROOT="${DOMAIN_DIR}/${SOURCE_DOMAIN}/public_html"
DESTINATION_ROOT="${DOMAIN_DIR}/${DESTINATION_DOMAIN}/public_html"

# Verify source exists
if [ ! -d "$SOURCE_ROOT" ]; then
    echo "❌ Error: Source directory not found: $SOURCE_ROOT"
    exit 1
fi

# --- STEP 1: READ SOURCE CONFIG ---

echo "Reading source configuration..."
# Run as root because user shell is restricted
DB_NAME=$(wp config get DB_NAME --path="$SOURCE_ROOT" --allow-root)
DB_USER_OLD=$(wp config get DB_USER --path="$SOURCE_ROOT" --allow-root)

if [ -z "$DB_NAME" ]; then
    echo "❌ Failed to read DB credentials from source."
    exit 1
fi

# --- STEP 2: SETUP DESTINATION DOMAIN & DB ---

echo "Creating destination domain: $DESTINATION_DOMAIN"
v-add-web-domain "$USER" "$DESTINATION_DOMAIN"

# --- [NEW] CLEANUP DEFAULT HESTIA FILES ---
echo "Removing default Hestia index.html..."
rm -f "${DESTINATION_ROOT}/index.html" "${DESTINATION_ROOT}/robots.txt"

# Detect IP address for DNS
USER_IP=$(v-list-user "$USER" json | grep '"IP":' | cut -d'"' -f4)

if [ -z "$USER_IP" ]; then
    echo "⚠️  Could not auto-detect User IP. Skipping separate DNS creation."
else
    echo "Adding DNS domain using IP: $USER_IP"
    v-add-dns-domain "$USER" "$DESTINATION_DOMAIN" "$USER_IP"
fi

# Generate NEW clean DB credentials
SHORT_NAME=$(echo "$DESTINATION_DOMAIN" | sed 's/\./_/g' | cut -c1-8)
NEW_DB_NAME="${SHORT_NAME}_db"
NEW_DB_USER="${SHORT_NAME}_user"
NEW_DB_PASS=$(openssl rand -base64 12)

echo "Creating new database: ${USER}_${NEW_DB_NAME}..."
v-add-database "$USER" "$NEW_DB_NAME" "$NEW_DB_USER" "$NEW_DB_PASS"

# --- STEP 3: MIGRATE DATA ---

echo "Cloning files (rsync)..."
# Destination dir already exists from v-add-web-domain
rsync -a --exclude 'wp-config.php' "${SOURCE_ROOT}/" "$DESTINATION_ROOT/"

echo "Dumping and Importing Database..."
DUMP_FILE="/tmp/${USER}_${DB_NAME}.sql"

mysqldump --defaults-extra-file=/root/.mysql.cnf "${DB_NAME}" > "$DUMP_FILE"
mysql --defaults-extra-file=/root/.mysql.cnf "${USER}_${NEW_DB_NAME}" < "$DUMP_FILE"
rm "$DUMP_FILE"

# --- STEP 4: CONFIGURE NEW SITE ---

echo "Generating new wp-config.php..."
cp "${SOURCE_ROOT}/wp-config.php" "${DESTINATION_ROOT}/wp-config.php"

sed -i "s/define( *'DB_NAME', *'.*' *);/define( 'DB_NAME', '${USER}_${NEW_DB_NAME}' );/" "${DESTINATION_ROOT}/wp-config.php"
sed -i "s/define( *'DB_USER', *'.*' *);/define( 'DB_USER', '${USER}_${NEW_DB_USER}' );/" "${DESTINATION_ROOT}/wp-config.php"
sed -i "s/define( *'DB_PASSWORD', *'.*' *);/define( 'DB_PASSWORD', '${NEW_DB_PASS}' );/" "${DESTINATION_ROOT}/wp-config.php"

# --- STEP 5: SEARCH & REPLACE AND CLEANUP ---

echo "Running Search & Replace (using root to bypass shell limits)..."
wp search-replace "https://$SOURCE_DOMAIN" "https://$DESTINATION_DOMAIN" --path="$DESTINATION_ROOT" --skip-columns=guid --allow-root
wp search-replace "http://$SOURCE_DOMAIN" "http://$DESTINATION_DOMAIN" --path="$DESTINATION_ROOT" --skip-columns=guid --allow-root

echo "Flushing Cache..."
wp cache flush --path="$DESTINATION_ROOT" --allow-root

echo "Fixing Permissions (Returning ownership to user)..."
chown -R "$USER:$USER" "$DESTINATION_ROOT"

echo "✅ Success! Site cloned to http://${DESTINATION_DOMAIN}"
echo "   Database: ${USER}_${NEW_DB_NAME}"
echo "   User: ${USER}_${NEW_DB_USER}"
echo "   Pass: ${NEW_DB_PASS}"