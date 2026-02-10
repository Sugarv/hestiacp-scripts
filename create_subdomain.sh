#!/bin/bash
# Create a Wordpress site clone on a given subdomain
# (useful for testing, migrations etc)
# Usage: ./create_subdomain.sh <username> <desired-subdomain-url>

# --- CONFIGURATION & CHECKS ---

# 1. Fix PATH so Hestia commands work
export PATH=$PATH:/usr/local/hestia/bin

# Check for WP-CLI
if ! command -v wp &> /dev/null; then
    echo "❌ Error: WP-CLI is not installed."
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

# Add the subdomain web
v-add-web-domain "$USER" "$SUBDOMAIN_URL"
if [ $? -ne 0 ]; then
    echo "Failed to add web domain for subdomain: $SUBDOMAIN_URL"
    exit 1
fi

# Try to add DNS domain - detect user IP first
echo "Reading source configuration..."
DOMAIN=$(echo "$SUBDOMAIN_URL" | cut -d. -f2-)
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

# 2. Smartly derive parent domain
# Assumes input is "sub.domain.com" -> Parent is "domain.com"
# Paths and domain info
DOMAIN=$(echo "$SUBDOMAIN_URL" | cut -d. -f2-)
SUBDOMAIN_PART=$(echo "$SUBDOMAIN_URL" | cut -d. -f1)

DOMAIN_DIR="/home/${USER}/web"
SOURCE_ROOT="${DOMAIN_DIR}/${DOMAIN}/public_html"
DESTINATION_ROOT="${DOMAIN_DIR}/${SUBDOMAIN_URL}/public_html"

# Verify source exists
if [ ! -d "$SOURCE_ROOT" ]; then
    echo "❌ Error: Parent domain directory not found: $SOURCE_ROOT"
    echo "   Ensure the parent domain is '$DOMAIN' and exists in Hestia."
    exit 1
fi

# Extract database details from wp-config.php
DB_NAME=$(grep -oP "define\s*\(\s*'DB_NAME'\s*,\s*'\K[^']+" "$WP_CONFIG_PATH")
DB_USER=$(grep -oP "define\s*\(\s*'DB_USER'\s*,\s*'\K[^']+" "$WP_CONFIG_PATH")
DB_PASS=$(grep -oP "define\s*\(\s*'DB_PASSWORD'\s*,\s*'\K[^']+" "$WP_CONFIG_PATH")
# --- STEP 1: READ SOURCE CONFIG ---

echo "Reading source configuration..."
# 3. Use WP-CLI to read config (Safer than grep)
DB_NAME=$(wp config get DB_NAME --path="$SOURCE_ROOT" --allow-root)
# We don't strictly need the old DB User/Pass because we are creating new ones

if [ -z "$DB_NAME" ]; then
    echo "❌ Failed to read DB credentials from source."
    exit 1
fi

# --- STEP 2: SETUP SUBDOMAIN & DB ---

# Dump the original database
DUMP_FILE="/tmp/${DB_NAME}.sql"
mysqldump $MYSQL_DEFAULTS "$DB_NAME" > "$DUMP_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to dump database: $DB_NAME"
    exit 1
echo "Creating subdomain: $SUBDOMAIN_URL"
v-add-web-domain "$USER" "$SUBDOMAIN_URL"

# 4. Remove default index.html immediately so it doesn't block WP
rm -f "${DESTINATION_ROOT}/index.html" "${DESTINATION_ROOT}/robots.txt"

# 5. Fix DNS: Auto-detect IP
USER_IP=$(v-list-user "$USER" json | grep '"IP":' | cut -d'"' -f4)
if [ -z "$USER_IP" ]; then
    echo "⚠️  Could not auto-detect User IP. Skipping DNS."
else
    echo "Adding DNS with IP: $USER_IP"
    v-add-dns-domain "$USER" "$SUBDOMAIN_URL" "$USER_IP"
fi

# 6. Database Setup
# Truncate subdomain part to ensure DB name isn't too long for MySQL
SHORT_SUB=$(echo "$SUBDOMAIN_PART" | cut -c1-8)
NEW_DB_NAME="${SHORT_SUB}_db"
NEW_DB_USER="${SHORT_SUB}_user"
NEW_DB_PASS=$(openssl rand -base64 12) # Generate fresh secure password

# Import original database dump into staging database
mysql $MYSQL_DEFAULTS "$STAGING_DB_NAME" < "$DUMP_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to import SQL file into staging database: $STAGING_DB_NAME"
    exit 1
fi
echo "Creating staging database: ${USER}_${NEW_DB_NAME}..."
v-add-database "$USER" "$NEW_DB_NAME" "$NEW_DB_USER" "$NEW_DB_PASS"

# --- STEP 3: MIGRATE DATA ---

echo "Cloning files (rsync)..."
mkdir -p "$DESTINATION_ROOT"
rsync -a --exclude 'wp-config.php' "${SOURCE_ROOT}/" "$DESTINATION_ROOT/"

# Update wp-config.php for the subdomain
SUBDOMAIN_WP_CONFIG="$SUBDOMAIN_DIR/wp-config.php"
sed -i "s|define( 'DB_NAME',.*|define( 'DB_NAME', '${STAGING_DB_NAME}');|" "$SUBDOMAIN_WP_CONFIG"
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to update DB_NAME in wp-config.php"
    exit 1
fi

sed -i "s|define( 'DB_USER',.*|define( 'DB_USER', '${DB_USER}');|" "$SUBDOMAIN_WP_CONFIG"
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to update DB_USER in wp-config.php"
    exit 1
fi

sed -i "s|define( 'DB_PASSWORD',.*|define( 'DB_PASSWORD', '${DB_PASS}');|" "$SUBDOMAIN_WP_CONFIG"
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to update DB_PASSWORD in wp-config.php"
    exit 1
fi
echo "Dumping and Importing Database..."
DUMP_FILE="/tmp/${USER}_${DB_NAME}.sql"

mysqldump --defaults-extra-file=/root/.mysql.cnf "${DB_NAME}" > "$DUMP_FILE"
mysql --defaults-extra-file=/root/.mysql.cnf "${USER}_${NEW_DB_NAME}" < "$DUMP_FILE"
rm "$DUMP_FILE"

# --- STEP 4: CONFIGURE NEW SITE ---

echo "Generating new wp-config.php..."
cp "${SOURCE_ROOT}/wp-config.php" "${DESTINATION_ROOT}/wp-config.php"

# 7. CRITICAL FIX: Update wp-config to use the NEW DB User, not the old one
sed -i "s/define( *'DB_NAME', *'.*' *);/define( 'DB_NAME', '${USER}_${NEW_DB_NAME}' );/" "${DESTINATION_ROOT}/wp-config.php"
sed -i "s/define( *'DB_USER', *'.*' *);/define( 'DB_USER', '${USER}_${NEW_DB_USER}' );/" "${DESTINATION_ROOT}/wp-config.php"
sed -i "s/define( *'DB_PASSWORD', *'.*' *);/define( 'DB_PASSWORD', '${NEW_DB_PASS}' );/" "${DESTINATION_ROOT}/wp-config.php"

# --- STEP 5: SEARCH & REPLACE ---

echo "Running Search & Replace..."
# 8. Run as root (to bypass shell limits) but fix permissions later
wp search-replace "https://$DOMAIN" "https://$SUBDOMAIN_URL" --path="$DESTINATION_ROOT" --skip-columns=guid --allow-root
wp search-replace "http://$DOMAIN" "http://$SUBDOMAIN_URL" --path="$DESTINATION_ROOT" --skip-columns=guid --allow-root

echo "Flushing Cache..."
wp cache flush --path="$DESTINATION_ROOT" --allow-root

# 9. CRITICAL FIX: Restore file ownership to the user
echo "Fixing Permissions..."
chown -R "$USER:$USER" "$DESTINATION_ROOT"

echo "✅ Success! Staging created at http://${SUBDOMAIN_URL}"
echo "   Database: ${USER}_${NEW_DB_NAME}"
echo "   User: ${USER}_${NEW_DB_USER}"
echo "   Pass: ${NEW_DB_PASS}"