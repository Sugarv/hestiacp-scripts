#!/bin/bash
# Moves a subdomain to the backup directory and replaces the main domain with the subdomain in the wp-config.php file.
# This script should be run on the HestiaCP server.

# Check if WP-CLI is available at the beginning
if ! command -v wp &> /dev/null
then
    echo "❌ Error: WP-CLI is not installed or not in your PATH. Please install it to proceed with serialization-safe URL replacement."
    echo "You can download it from: https://wp-cli.org/#install"
    exit 1
fi

# Ask for HestiaCP username and subdomain
read -p "Enter your HestiaCP username: " USER
read -p "Enter the subdomain (e.g., test.example.com): " SUBDOMAIN

# Extract main domain by removing the first part of the subdomain
MAINDOMAIN=$(echo "$SUBDOMAIN" | sed -E 's/^[^.]+\.//')

# Define paths
WEB_ROOT="/home/$USER/web"
BACKUP_DIR="/home/$USER/backup"

# Before beginning, backup the main domain files to backup folder
mkdir -p $BACKUP_DIR
tar -czf $BACKUP_DIR/$MAINDOMAIN-files-$(date +%F).tar.gz $WEB_ROOT/$MAINDOMAIN/public_html


# Verify subdomain wp-config.php exists before proceeding
WP_CONFIG_SUB="$WEB_ROOT/$SUBDOMAIN/public_html/wp-config.php"
if [ ! -f "$WP_CONFIG_SUB" ]; then
    echo "❌ Error: wp-config.php not found in $WEB_ROOT/$SUBDOMAIN/public_html"
    exit 1
fi

# Get subdomain database details from wp-config.php
DB_NAME_SUB=$(grep DB_NAME $WP_CONFIG_SUB | cut -d "'" -f4)
DB_USER_SUB=$(grep DB_USER $WP_CONFIG_SUB | cut -d "'" -f4)
DB_PASS_SUB=$(grep DB_PASSWORD $WP_CONFIG_SUB | cut -d "'" -f4)
# dump the subdomain database to backup folder
mysqldump -u $DB_USER_SUB -p$DB_PASS_SUB $DB_NAME_SUB > $BACKUP_DIR/$MAINDOMAIN-sub-db-$(date +%F).sql

# Move files from subdomain to main domain
rsync -av --remove-source-files $WEB_ROOT/$SUBDOMAIN/public_html/ $WEB_ROOT/$MAINDOMAIN/public_html/
rm -r $WEB_ROOT/$SUBDOMAIN

# Verify main domain wp-config.php exists before proceeding
WP_CONFIG="$WEB_ROOT/$MAINDOMAIN/public_html/wp-config.php"
if [ ! -f "$WP_CONFIG" ]; then
    echo "❌ Error: wp-config.php not found in $WEB_ROOT/$MAINDOMAIN/public_html"
    exit 1
fi
# Get main domain database details from wp-config.php
DB_NAME=$(grep DB_NAME $WP_CONFIG | cut -d "'" -f4)
DB_USER=$(grep DB_USER $WP_CONFIG | cut -d "'" -f4)
DB_PASS=$(grep DB_PASSWORD $WP_CONFIG | cut -d "'" -f4)

# Backup the main domain database before proceeding
mysqldump -u $DB_USER -p$DB_PASS $DB_NAME > $BACKUP_DIR/$MAINDOMAIN-old_db-$(date +%F).sql

# Upload subdomain database to main domain
mysql -u $DB_USER -p$DB_PASS $DB_NAME < $BACKUP_DIR/$MAINDOMAIN-sub-db-$(date +%F).sql

# Update database: Replace subdomain URLs with main domain using WP-CLI for serialization safety
echo "Updating database URLs using WP-CLI..."
WP_PATH="$WEB_ROOT/$MAINDOMAIN/public_html"

# Perform search-replace operations
# Note: wp search-replace is serialization-aware by default.
# The --precise flag can be added for more aggressive (but slower) serialization handling
# if issues arise with complex or malformed serialized data.
wp search-replace "https://$SUBDOMAIN" "https://$MAINDOMAIN" --path="$WP_PATH" --skip-columns=guid --allow-root
if [ $? -ne 0 ]; then
    echo "❌ Error: WP-CLI search-replace failed for HTTPS URLs."
    exit 1
fi
wp search-replace "http://$SUBDOMAIN" "http://$MAINDOMAIN" --path="$WP_PATH" --skip-columns=guid --allow-root
if [ $? -ne 0 ]; then
    echo "❌ Error: WP-CLI search-replace failed for HTTP URLs."
    exit 1
fi

# Clear WP-CLI cache
wp cache flush --path="$WP_PATH" --allow-root

# Restart services
systemctl restart nginx apache2 php8.1-fpm  # Update PHP version if needed

echo "✅ Migration from $SUBDOMAIN to $MAINDOMAIN completed!"