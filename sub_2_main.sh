#!/bin/bash

# Ask for HestiaCP username and subdomain
read -p "Enter your HestiaCP username: " USER
read -p "Enter the subdomain (e.g., test.example.com): " SUBDOMAIN

# Extract main domain by removing the first part of the subdomain
MAINDOMAIN=$(echo "$SUBDOMAIN" | sed -E 's/^[^.]+\.//')

# Define paths
WEB_ROOT="/home/$USER/web"
BACKUP_DIR="/home/$USER/backup"

# Verify wp-config.php exists before proceeding
WP_CONFIG="$WEB_ROOT/$SUBDOMAIN/public_html/wp-config.php"
if [ ! -f "$WP_CONFIG" ]; then
    echo "❌ Error: wp-config.php not found in $WEB_ROOT/$SUBDOMAIN/public_html"
    exit 1
fi

# Get database details from wp-config.php
DB_NAME=$(grep DB_NAME $WP_CONFIG | cut -d "'" -f4)
DB_USER=$(grep DB_USER $WP_CONFIG | cut -d "'" -f4)
DB_PASS=$(grep DB_PASSWORD $WP_CONFIG | cut -d "'" -f4)

# Backup the main domain (files & database)
mkdir -p $BACKUP_DIR
tar -czf $BACKUP_DIR/$MAINDOMAIN-files-$(date +%F).tar.gz $WEB_ROOT/$MAINDOMAIN/public_html
mysqldump -u $DB_USER -p$DB_PASS $DB_NAME > $BACKUP_DIR/$MAINDOMAIN-db-$(date +%F).sql

# Move files from subdomain to main domain
rsync -av --remove-source-files $WEB_ROOT/$SUBDOMAIN/public_html/ $WEB_ROOT/$MAINDOMAIN/public_html/
rm -r $WEB_ROOT/$SUBDOMAIN

# Update database: Replace subdomain URLs with main domain
mysql -u $DB_USER -p$DB_PASS $DB_NAME <<EOF
UPDATE wp_options SET option_value = REPLACE(option_value, '$SUBDOMAIN', '$MAINDOMAIN') WHERE option_name IN ('siteurl', 'home');
UPDATE wp_posts SET guid = REPLACE(guid, '$SUBDOMAIN', '$MAINDOMAIN');
UPDATE wp_posts SET post_content = REPLACE(post_content, '$SUBDOMAIN', '$MAINDOMAIN');
UPDATE wp_postmeta SET meta_value = REPLACE(meta_value, '$SUBDOMAIN', '$MAINDOMAIN');
UPDATE wp_usermeta SET meta_value = REPLACE(meta_value, '$SUBDOMAIN', '$MAINDOMAIN');
UPDATE wp_comments SET comment_content = REPLACE(comment_content, '$SUBDOMAIN', '$MAINDOMAIN');
EOF

# Restart services
systemctl restart nginx apache2 php8.1-fpm  # Update PHP version if needed

echo "✅ Migration from $SUBDOMAIN to $MAINDOMAIN completed!"