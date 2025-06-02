#!/bin/bash

# Ensure script is run with necessary arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <user> <source-domain> <destination-domain>"
    exit 1
fi

# Input arguments
USER="$1"
SOURCE_DOMAIN="$2"
DESTINATION_DOMAIN="$3"

# File with MySQL root credentials
MYSQL_CRED_FILE="/root/.mysql.cnf"

if [ ! -f "$MYSQL_CRED_FILE" ]; then
    echo "MySQL credentials file not found: $MYSQL_CRED_FILE"
    exit 1
fi

# Add the destination domain
v-add-web-domain "$USER" "$DESTINATION_DOMAIN"
if [ $? -ne 0 ]; then
    echo "Failed to add web domain for destination: $DESTINATION_DOMAIN"
    exit 1
fi


DB_NAME=$(grep -oP "define\( 'DB_NAME',\s*'\K[^']+" "$SOURCE_WP_CONFIG_PATH")
DB_USER=$(grep -oP "define\( 'DB_USER',\s*'\K[^']+" "$SOURCE_WP_CONFIG_PATH")
DB_PASS=$(grep -oP "define\( 'DB_PASSWORD',\s*'\K[^']+" "$SOURCE_WP_CONFIG_PATH")

if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
    echo "Failed to extract database details from wp-config.php: $SOURCE_WP_CONFIG_PATH"
    exit 1
fi

# Dump the source database
DUMP_FILE="/tmp/${DB_NAME}.sql"
mysqldump --defaults-extra-file="$MYSQL_CRED_FILE" "$DB_NAME" > "$DUMP_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to dump database: $DB_NAME"
    exit 1
fi

# Replace source domain with destination domain in SQL file
sed -i "s/${SOURCE_DOMAIN}/${DESTINATION_DOMAIN}/g" "$DUMP_FILE"
echo "Replaced ${SOURCE_DOMAIN} with ${DESTINATION_DOMAIN} in SQL dump."

# Create new database for destination domain
DESTINATION_DB_NAME_SHORT="$(echo "$DESTINATION_DOMAIN" | cut -d. -f1)"
DESTINATION_DB_NAME="${USER}_$(echo "$DESTINATION_DOMAIN" | cut -d. -f1)"
v-add-database "$USER" "$DESTINATION_DB_NAME_SHORT" "$DB_USER" "$DB_PASS"
if [ $? -ne 0 ]; then
    echo "Failed to create database for destination domain"
    exit 1
fi

# Import modified SQL file into destination database
mysql --defaults-extra-file="$MYSQL_CRED_FILE" "$DESTINATION_DB_NAME" < "$DUMP_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to import SQL file into destination database: $DESTINATION_DB_NAME"
    exit 1
fi

# Copy files from source to destination
mkdir -p "$DESTINATION_DIR"
rsync -a "${DOMAIN_DIR}/${SOURCE_DOMAIN}/public_html/" "$DESTINATION_DIR"

# Update wp-config.php for the destination domain
DESTINATION_WP_CONFIG="$DESTINATION_DIR/wp-config.php"
sed -i "s/define( 'DB_NAME',.*/define( 'DB_NAME', '${DESTINATION_DB_NAME}');/" "$DESTINATION_WP_CONFIG"
sed -i "s/define( 'DB_USER',.*/define( 'DB_USER', '${DB_USER}');/" "$DESTINATION_WP_CONFIG"
sed -i "s/define( 'DB_PASSWORD',.*/define( 'DB_PASSWORD', '${DB_PASS}');/" "$DESTINATION_WP_CONFIG"

# Cleanup
rm "$DUMP_FILE"

echo "WordPress site successfully cloned from ${SOURCE_DOMAIN} to ${DESTINATION_DOMAIN}"