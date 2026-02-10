#!/bin/bash

# ==========================================
# PLESK TO HESTIA SMART RESTORE (XML PARSER)
# ==========================================
# Usage: ./plesk_smart_restore.sh <backup_file.tar> <new_hestia_user>

BACKUP_FILE=$1
HESTIA_USER=$2

# Input Validation
if [ -z "$BACKUP_FILE" ] || [ -z "$HESTIA_USER" ]; then
    echo "Usage: ./plesk_smart_restore.sh <path_to_backup.tar> <new_hestia_user>"
    echo "Example: ./plesk_smart_restore.sh /backup/backup_info.tar myclient"
    exit 1
fi

# 1. Setup Environment
WORK_DIR="/root/plesk_migration_temp"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
echo ">>> Extracting Main Backup Archive..."
tar -xf "$BACKUP_FILE" -C "$WORK_DIR"

# 2. Find and Parse XML
XML_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "*.xml" | head -n 1)
if [ -z "$XML_FILE" ]; then
    echo "Error: No XML metadata file found in the root of the backup."
    exit 1
fi
echo ">>> Found metadata: $XML_FILE"

# 3. Use Python to Parse XML and Generate a Config
# We do this because parsing XML with Bash grep is dangerous and error-prone.
PYTHON_PARSER=$(cat <<EOF
import xml.etree.ElementTree as ET
import sys

try:
    tree = ET.parse('$XML_FILE')
    root = tree.getroot()
    
    # Namespace handling usually not needed for simple attributes, but good to be safe
    domain_node = root.find(".//domain")
    if domain_node is None:
        print("ERROR: No domain found")
        sys.exit(1)
        
    domain_name = domain_node.get('name')
    print(f"DOMAIN_NAME='{domain_name}'")
    
    # Emails
    print("declare -A EMAILS")
    print("declare -A EMAIL_PASS")
    mail_users = domain_node.findall(".//mailuser")
    for i, user in enumerate(mail_users):
        name = user.get('name')
        # Skip internal system users if any
        pass_node = user.find(".//password")
        if pass_node is not None and pass_node.get('type') == 'plain':
            password = pass_node.text
            # Escape single quotes for bash
            password = password.replace("'", "'\\\\''")
            print(f"EMAILS[{i}]='{name}'")
            print(f"EMAIL_PASS[{i}]='{password}'")

    # Databases
    print("declare -A DBS")
    print("declare -A DB_USERS")
    print("declare -A DB_PASS")
    databases = domain_node.findall(".//database")
    for i, db in enumerate(databases):
        db_name = db.get('name')
        db_user_node = db.find(".//dbuser")
        if db_user_node is not None:
            db_user = db_user_node.get('name')
            pass_node = db_user_node.find(".//password")
            if pass_node is not None and pass_node.get('type') == 'plain':
                password = pass_node.text
                password = password.replace("'", "'\\\\''")
                print(f"DBS[{i}]='{db_name}'")
                print(f"DB_USERS[{i}]='{db_user}'")
                print(f"DB_PASS[{i}]='{password}'")

except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
EOF
)

# Run the python parser and source the output variables
eval "$(python3 -c "$PYTHON_PARSER")"

if [ -z "$DOMAIN_NAME" ]; then
    echo "Failed to extract Domain Name from XML."
    exit 1
fi

echo ">>> Detected Domain: $DOMAIN_NAME"

# 4. Hestia User Setup
if ! v-list-user "$HESTIA_USER" &> /dev/null; then
    echo ">>> Creating Hestia User: $HESTIA_USER"
    PASS=$(openssl rand -base64 12)
    v-add-user "$HESTIA_USER" "$PASS" "admin@$DOMAIN_NAME"
fi

# 5. Create Domain
if ! v-list-web-domain "$HESTIA_USER" "$DOMAIN_NAME" &> /dev/null; then
    echo ">>> Adding Web Domain..."
    v-add-web-domain "$HESTIA_USER" "$DOMAIN_NAME"
fi
if ! v-list-mail-domain "$HESTIA_USER" "$DOMAIN_NAME" &> /dev/null; then
    echo ">>> Adding Mail Domain..."
    v-add-mail-domain "$HESTIA_USER" "$DOMAIN_NAME"
fi

# 6. Restore Emails (Using recovered passwords)
echo ">>> Restoring Email Accounts..."
for i in "${!EMAILS[@]}"; do
    USER="${EMAILS[$i]}"
    PASS="${EMAIL_PASS[$i]}"
    
    if [ -n "$USER" ] && [ -n "$PASS" ]; then
        echo "   + Creating $USER@$DOMAIN_NAME (Password restored)"
        v-add-mail-account "$HESTIA_USER" "$DOMAIN_NAME" "$USER" "$PASS"
    fi
done

# 7. Unpack Data Archives (ZSTD)
echo ">>> Unpacking internal .tzst data archives (this takes time)..."
find "$WORK_DIR" -name "*.tzst" -exec tar --use-compress-program=unzstd -xf {} -C "$WORK_DIR" \;

# 8. Move Web Files
echo ">>> Migrating Website Files..."
# Heuristic to find httpdocs
SOURCE_WEB=$(find "$WORK_DIR" -type d -name "httpdocs" | grep "$DOMAIN_NAME" | head -n 1)
TARGET_WEB="/home/$HESTIA_USER/web/$DOMAIN_NAME/public_html"

if [ -d "$SOURCE_WEB" ]; then
    rm -rf "$TARGET_WEB"/*
    cp -r "$SOURCE_WEB"/. "$TARGET_WEB"/
    chown -R "$HESTIA_USER:$HESTIA_USER" "$TARGET_WEB"
    echo "   + Files moved."
else
    echo "   ! WARNING: Could not auto-locate httpdocs folder."
fi

# 9. Restore Databases
echo ">>> Migrating Databases..."
for i in "${!DBS[@]}"; do
    OLD_DB="${DBS[$i]}"
    OLD_USER="${DB_USERS[$i]}"
    DB_PASS="${DB_PASS[$i]}"
    
    # Hestia enforces prefix
    NEW_DB="${HESTIA_USER}_${OLD_DB}"
    NEW_USER="${HESTIA_USER}_${OLD_USER}"
    
    # Shorten if too long (Hestia limit)
    NEW_DB=${NEW_DB:0:30} # Trim to 30 chars max
    NEW_USER=${NEW_USER:0:30}

    echo "   + Restoring DB: $OLD_DB -> $NEW_DB"
    
    v-add-database "$HESTIA_USER" "$NEW_DB" "$NEW_USER" "$DB_PASS"
    
    # Find SQL Dump
    # Plesk usually puts them in databases/db_name/backup.sql
    SQL_DUMP=$(find "$WORK_DIR" -name "*.sql" | grep "$OLD_DB" | head -n 1) || \
    SQL_DUMP=$(find "$WORK_DIR" -name "*.sql" | head -n 1) # Fallback

    if [ -f "$SQL_DUMP" ]; then
        mysql -u "$NEW_USER" -p"$DB_PASS" "$NEW_DB" < "$SQL_DUMP"
        echo "   + SQL Imported."
        
        # WP-Config Update
        CONFIG_FILE="$TARGET_WEB/wp-config.php"
        if [ -f "$CONFIG_FILE" ]; then
            echo "   + Updating wp-config.php..."
            sed -i "s/DB_NAME', '.*'/DB_NAME', '$NEW_DB'/" "$CONFIG_FILE"
            sed -i "s/DB_USER', '.*'/DB_USER', '$NEW_USER'/" "$CONFIG_FILE"
            sed -i "s/DB_PASSWORD', '.*'/DB_PASSWORD', '$DB_PASS'/" "$CONFIG_FILE"
        fi
    else
        echo "   ! WARNING: Could not find SQL dump for $OLD_DB"
    fi
done

# 10. Restore Email Content (Maildir)
echo ">>> Syncing Email Content..."
# Plesk Maildir structure in backup usually: .../mailnames/domain.com/user/Maildir
for i in "${!EMAILS[@]}"; do
    USER="${EMAILS[$i]}"
    # Find the Maildir for this specific user in the extracted backup
    SOURCE_MAIL=$(find "$WORK_DIR" -type d -path "*/$USER/Maildir" | head -n 1)
    TARGET_MAIL="/home/$HESTIA_USER/mail/$DOMAIN_NAME/$USER"
    
    if [ -d "$SOURCE_MAIL" ] && [ -d "$TARGET_MAIL" ]; then
        echo "   + Syncing email data for $USER..."
        # We use rsync to merge cur/new/tmp folders
        rsync -a "$SOURCE_MAIL/" "$TARGET_MAIL/"
        # Fix Permissions (Critical for Dovecot)
        chown -R "$HESTIA_USER:mail" "$TARGET_MAIL"
        find "$TARGET_MAIL" -type d -exec chmod 751 {} \;
        find "$TARGET_MAIL" -type f -exec chmod 640 {} \;
    fi
done

echo "=========================================="
echo "MIGRATION COMPLETE"
echo "Check your website: http://$DOMAIN_NAME"
echo "If everything works, remove temp files: rm -rf $WORK_DIR"
echo "=========================================="
