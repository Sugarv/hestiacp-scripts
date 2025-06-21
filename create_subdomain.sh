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

# File with MySQL root credentials
MYSQL_CRED_FILE="/root/.mysql.cnf"

if [ ! -f "$MYSQL_CRED_FILE" ]; then
    echo "MySQL credentials file not found: $MYSQL_CRED_FILE"
    exit 1
fi

# Add the subdomain web 
v-add-web-domain "$USER" "$SUBDOMAIN_URL"
if [ $? -ne 0 ]; then
    echo "Failed to add web domain for subdomain: $SUBDOMAIN_URL"
    exit 1
fi

# Add the subdomain DNS 
v-add-dns-domain "$USER" "$SUBDOMAIN_URL"
if [ $? -ne 0 ]; then
    echo "Failed to add DNS domain for subdomain: $SUBDOMAIN_URL"
    exit 1
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
DB_NAME=$(grep -oP "define\( 'DB_NAME',\s*'\K[^']+" "$WP_CONFIG_PATH")
DB_USER=$(grep -oP "define\( 'DB_USER',\s*'\K[^']+" "$WP_CONFIG_PATH")
DB_PASS=$(grep -oP "define\( 'DB_PASSWORD',\s*'\K[^']+" "$WP_CONFIG_PATH")

if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
    echo "Failed to extract database details from wp-config.php: $WP_CONFIG_PATH"
    exit 1
fi

echo "DB: ${DB_NAME}"
echo "DB_USER: ${DB_USER}"

# Dump the original database
DUMP_FILE="/tmp/${DB_NAME}.sql"
mysqldump --defaults-extra-file="$MYSQL_CRED_FILE" "$DB_NAME" > "$DUMP_FILE"
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
mysql --defaults-extra-file="$MYSQL_CRED_FILE" "$STAGING_DB_NAME" < "$DUMP_FILE"
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
sed -i "s/define( 'DB_NAME',.*/define( 'DB_NAME', '${STAGING_DB_NAME}');/" "$SUBDOMAIN_WP_CONFIG"
sed -i "s/define( 'DB_USER',.*/define( 'DB_USER', '${DB_USER}');/" "$SUBDOMAIN_WP_CONFIG"
sed -i "s/define( 'DB_PASSWORD',.*/define( 'DB_PASSWORD', '${DB_PASS}');/" "$SUBDOMAIN_WP_CONFIG"

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