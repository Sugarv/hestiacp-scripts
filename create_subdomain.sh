#!/bin/bash
# Create a Wordpress site clone on a given subdomain
# (useful for testing, migrations etc)
# Usage: create_subdomain.sh <username> <desired-subdomain-url>

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

# Paths and domain info
DOMAIN_DIR="/home/${USER}/web"
DOMAIN=$(echo "$SUBDOMAIN_URL" | cut -d. -f2-)
SUBDOMAIN_PART=$(echo "$SUBDOMAIN_URL" | cut -d. -f1)
WP_CONFIG_PATH="${DOMAIN_DIR}/${DOMAIN}/public_html/wp-config.php"

if [ ! -f "$WP_CONFIG_PATH" ]; then
    echo "WordPress configuration file not found: $WP_CONFIG_PATH"
    exit 1
fi

# Extract database details from wp-config.php
DB_NAME=$(grep -oP "define\s*\(\s*'DB_NAME'\s*,\s*'\K[^']+" "$WP_CONFIG_PATH")
DB_USER=$(grep -oP "define\s*\(\s*'DB_USER'\s*,\s*'\K[^']+" "$WP_CONFIG_PATH")
DB_PASS=$(grep -oP "define\s*\(\s*'DB_PASSWORD'\s*,\s*'\K[^']+" "$WP_CONFIG_PATH")

if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
    echo "Failed to extract database details from wp-config.php: $WP_CONFIG_PATH"
    exit 1
fi

echo "DB: ${DB_NAME}"
echo "DB_USER: ${DB_USER}"

# Dump the original database
DUMP_FILE="/tmp/${DB_NAME}.sql"
mysqldump $MYSQL_DEFAULTS "$DB_NAME" > "$DUMP_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to dump database: $DB_NAME"
    exit 1
fi

# Create new staging database
STAGING_DB_NAME="${USER}_${SUBDOMAIN_PART}"
v-add-database "$USER" "${SUBDOMAIN_PART}" "$SUBDOMAIN_PART" "$DB_PASS"
if [ $? -ne 0 ]; then
    echo "Failed to create staging database"
    exit 1
fi

# Import original database dump into staging database
mysql $MYSQL_DEFAULTS "$STAGING_DB_NAME" < "$DUMP_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to import SQL file into staging database: $STAGING_DB_NAME"
    exit 1
fi

# Set up the subdomain files
SUBDOMAIN_DIR="${DOMAIN_DIR}/${SUBDOMAIN_URL}/public_html"
mkdir -p "$SUBDOMAIN_DIR"
rsync -a "${DOMAIN_DIR}/${DOMAIN}/public_html/" "$SUBDOMAIN_DIR"

# Delete index.html (WP uses index.php)
rm "$SUBDOMAIN_DIR/index.html"

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

# Perform search-replace operations using WP-CLI for serialization safety
echo "Updating database URLs using WP-CLI..."
WP_PATH="${DOMAIN_DIR}/${SUBDOMAIN_URL}/public_html"

# Note: wp search-replace is serialization-aware by default.
# The --precise flag can be added for more aggressive (but slower) serialization handling
# if issues arise with complex or malformed serialized data.
wp search-replace "https://$DOMAIN" "https://$SUBDOMAIN_URL" --path="$WP_PATH" --skip-columns=guid --allow-root
if [ $? -ne 0 ]; then
    echo "❌ Error: WP-CLI search-replace failed for HTTPS URLs."
    exit 1
fi
wp search-replace "http://$DOMAIN" "http://$SUBDOMAIN_URL" --path="$WP_PATH" --skip-columns=guid --allow-root
if [ $? -ne 0 ]; then
    echo "❌ Error: WP-CLI search-replace failed for HTTP URLs."
    exit 1
fi

# Clear WP-CLI cache
wp cache flush --path="$WP_PATH" --allow-root
if [ $? -ne 0 ]; then
    echo "❌ Error: WP-CLI cache flush failed."
    exit 1
fi

# Cleanup
rm "$DUMP_FILE"

echo "WordPress site successfully copied to subdomain: $SUBDOMAIN_URL"