#!/bin/bash
# Create a Wordpress site clone on a given subdomain
# (useful for testing, migrations etc)
# Usage: create_subdomain.sh <username> <desired-subdomain-url>

# Fix PATH so Hestia commands work
export PATH=$PATH:/usr/local/hestia/bin

# Check if WP-CLI is available at the beginning
if ! command -v wp &> /dev/null
then
    echo "❌ Error: WP-CLI is not installed or not in your PATH. Please install it to proceed with serialization-safe URL replacement."
    echo "You can download it from: https://wp-cli.org/#install"
    exit 1
fi

# Ensure script is run with necessary arguments
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <username> <desired-subdomain-url>"
    exit 1
fi

# Input arguments
USER="$1"
SUBDOMAIN_URL="$2"

# File with MySQL credentials
MYSQL_CRED_FILE="/root/.my.cnf"

# Check if credentials file exists, if not continue without it (MySQL may use other auth methods)
MYSQL_DEFAULTS=""
if [ -f "$MYSQL_CRED_FILE" ]; then
    MYSQL_DEFAULTS="--defaults-extra-file=$MYSQL_CRED_FILE"
fi

# --- STEP 1: DERIVE PATHS AND VALIDATE SOURCE ---

# Derive parent domain and subdomain part
DOMAIN=$(echo "$SUBDOMAIN_URL" | cut -d. -f2-)
SUBDOMAIN_PART=$(echo "$SUBDOMAIN_URL" | cut -d. -f1)

DOMAIN_DIR="/home/${USER}/web"
SOURCE_ROOT="${DOMAIN_DIR}/${DOMAIN}/public_html"
DESTINATION_ROOT="${DOMAIN_DIR}/${SUBDOMAIN_URL}/public_html"
SOURCE_WP_CONFIG="${SOURCE_ROOT}/wp-config.php"

# Verify source WordPress exists
if [ ! -d "$SOURCE_ROOT" ]; then
    echo "❌ Error: Parent domain directory not found: $SOURCE_ROOT"
    echo "   Ensure the parent domain is '$DOMAIN' and exists in Hestia."
    exit 1
fi

if [ ! -f "$SOURCE_WP_CONFIG" ]; then
    echo "❌ Error: WordPress configuration file not found: $SOURCE_WP_CONFIG"
    exit 1
fi

# --- STEP 2: READ SOURCE DATABASE CONFIG ---

echo "Reading source configuration..."
# Use WP-CLI to safely read database name from source
DB_NAME=$(wp config get DB_NAME --path="$SOURCE_ROOT" --allow-root)

if [ -z "$DB_NAME" ]; then
    echo "❌ Failed to read DB_NAME from source wp-config.php"
    exit 1
fi

# --- STEP 3: ADD SUBDOMAIN WEB DOMAIN ---

echo "Creating subdomain: $SUBDOMAIN_URL"
v-add-web-domain "$USER" "$SUBDOMAIN_URL"
if [ $? -ne 0 ]; then
    echo "Failed to add web domain for subdomain: $SUBDOMAIN_URL"
    exit 1
fi

# --- STEP 4: ADD DNS DOMAIN (with IP detection) ---

# Try to extract IP from HestiaCP config
APACHE_CONFIG="/home/${USER}/conf/web/${DOMAIN}/apache2.conf"
USER_IP=""

if [ -f "$APACHE_CONFIG" ]; then
    USER_IP=$(grep -oP "VirtualHost\s+\K[\d.]+" "$APACHE_CONFIG" | head -1)
fi

if [ -z "$USER_IP" ]; then
    echo "⚠️  Could not auto-detect User IP. Skipping DNS."
else
    v-add-dns-domain "$USER" "$SUBDOMAIN_URL" "$USER_IP"
    if [ $? -ne 0 ]; then
        echo "⚠️  Warning: Failed to add DNS domain for subdomain: $SUBDOMAIN_URL (continuing anyway)"
    fi
fi

# --- STEP 5: DUMP SOURCE DATABASE ---

echo "Dumping and Importing Database..."
DUMP_FILE="/tmp/${DB_NAME}_$(date +%s).sql"
mysqldump $MYSQL_DEFAULTS "$DB_NAME" > "$DUMP_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to dump database: $DB_NAME"
    exit 1
fi

# --- STEP 6: CREATE STAGING DATABASE ---

# Generate database credentials for the subdomain
SHORT_SUB=$(echo "$SUBDOMAIN_PART" | cut -c1-8)
NEW_DB_NAME="${SHORT_SUB}_db"
NEW_DB_USER="${SHORT_SUB}_user"
NEW_DB_PASS=$(openssl rand -base64 12)
STAGING_DB_NAME="${USER}_${NEW_DB_NAME}"
STAGING_DB_USER="${USER}_${NEW_DB_USER}"

# Create the new database via Hestia
v-add-database "$USER" "$NEW_DB_NAME" "$NEW_DB_USER" "$NEW_DB_PASS"
if [ $? -ne 0 ]; then
    echo "Failed to create staging database"
    exit 1
fi

# Import the dump into staging database
mysql $MYSQL_DEFAULTS "$STAGING_DB_NAME" < "$DUMP_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to import SQL file into staging database: $STAGING_DB_NAME"
    exit 1
fi

# Clean up dump file
rm "$DUMP_FILE"

# --- STEP 7: CLONE FILES ---

echo "Cloning files (rsync)..."
mkdir -p "$DESTINATION_ROOT"
rsync -a "${SOURCE_ROOT}/" "$DESTINATION_ROOT"
if [ $? -ne 0 ]; then
    echo "Failed to rsync files from source to subdomain"
    exit 1
fi

# Delete index.html (WP uses index.php)
rm -f "$DESTINATION_ROOT/index.html"

# --- STEP 8: UPDATE WP-CONFIG.PHP ---

echo "Generating new wp-config.php..."
SUBDOMAIN_WP_CONFIG="$DESTINATION_ROOT/wp-config.php"

# Update database name using proper sed delimiter (pipe) to avoid issues with special chars
sed -i "s|define\s*(\s*'DB_NAME'\s*,\s*'[^']*'|define( 'DB_NAME', '${STAGING_DB_NAME}'|" "$SUBDOMAIN_WP_CONFIG"
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to update DB_NAME in wp-config.php"
    exit 1
fi

sed -i "s|define\s*(\s*'DB_USER'\s*,\s*'[^']*'|define( 'DB_USER', '${STAGING_DB_USER}'|" "$SUBDOMAIN_WP_CONFIG"
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to update DB_USER in wp-config.php"
    exit 1
fi

sed -i "s|define\s*(\s*'DB_PASSWORD'\s*,\s*'[^']*'|define( 'DB_PASSWORD', '${NEW_DB_PASS}'|" "$SUBDOMAIN_WP_CONFIG"
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to update DB_PASSWORD in wp-config.php"
    exit 1
fi

# --- STEP 9: RUN SEARCH & REPLACE ---

echo "Running Search & Replace..."
WP_PATH="$DESTINATION_ROOT"

# Use WP-CLI for serialization-safe URL replacement
wp search-replace "https://$DOMAIN" "https://$SUBDOMAIN_URL" --path="$WP_PATH" --skip-columns=guid --allow-root
if [ $? -ne 0 ]; then
    echo "⚠️  Warning: WP-CLI search-replace failed for HTTPS URLs (continuing anyway)"
fi

wp search-replace "http://$DOMAIN" "http://$SUBDOMAIN_URL" --path="$WP_PATH" --skip-columns=guid --allow-root
if [ $? -ne 0 ]; then
    echo "⚠️  Warning: WP-CLI search-replace failed for HTTP URLs (continuing anyway)"
fi

# --- STEP 10: FLUSH CACHE ---

echo "Flushing Cache..."
wp cache flush --path="$WP_PATH" --allow-root
if [ $? -ne 0 ]; then
    echo "⚠️  Warning: WP-CLI cache flush failed (continuing anyway)"
fi

# --- STEP 11: FIX PERMISSIONS ---

echo "Fixing Permissions..."
chown -R "$USER:$USER" "$DESTINATION_ROOT"

# Success message
echo "✅ Success! Staging created at http://${SUBDOMAIN_URL}"
echo "   Database: ${STAGING_DB_NAME}"
echo "   User: ${STAGING_DB_USER}"
echo "   Pass: ${NEW_DB_PASS}"
