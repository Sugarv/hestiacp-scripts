#!/bin/bash
# Pushes a subdomain (Staging) to the Main Domain (Production)
# Usage: ./push_production.sh

# --- CONFIGURATION & CHECKS ---

# Add Hestia binaries to PATH
export PATH=$PATH:/usr/local/hestia/bin

# Check for WP-CLI
if ! command -v wp &> /dev/null; then
    echo "❌ Error: WP-CLI is not installed."
    exit 1
fi

# Ask for inputs if not provided as arguments
if [ -z "$1" ]; then
    read -p "Enter your HestiaCP username: " USER
else
    USER=$1
fi

if [ -z "$2" ]; then
    read -p "Enter the subdomain (e.g., test.example.com): " SUBDOMAIN
else
    SUBDOMAIN=$2
fi

# Auto-detect Main Domain (assumes sub.domain.com format)
MAINDOMAIN=$(echo "$SUBDOMAIN" | cut -d. -f2-)

WEB_ROOT="/home/$USER/web"
SUB_ROOT="$WEB_ROOT/$SUBDOMAIN/public_html"
MAIN_ROOT="$WEB_ROOT/$MAINDOMAIN/public_html"
BACKUP_DIR="/home/$USER/backup_manual"

# Verify directories
if [ ! -d "$SUB_ROOT" ] || [ ! -d "$MAIN_ROOT" ]; then
    echo "❌ Error: Could not find directories for $SUBDOMAIN or $MAINDOMAIN"
    exit 1
fi

echo "🚀 Starting Push: $SUBDOMAIN -> $MAINDOMAIN"

# --- STEP 1: BACKUP PRODUCTION (SAFETY FIRST) ---

echo "📦 Backing up current Production site..."
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%F_%H-%M)

# Backup Files
tar -czf "$BACKUP_DIR/${MAINDOMAIN}_files_${TIMESTAMP}.tar.gz" -C "$MAIN_ROOT" .

# Backup Database (Read credentials safely via WP-CLI)
DB_NAME_MAIN=$(wp config get DB_NAME --path="$MAIN_ROOT" --allow-root)
DB_USER_MAIN=$(wp config get DB_USER --path="$MAIN_ROOT" --allow-root)
DB_PASS_MAIN=$(wp config get DB_PASSWORD --path="$MAIN_ROOT" --allow-root)

if [ -z "$DB_NAME_MAIN" ]; then
    echo "❌ Error: Could not read Main Domain DB credentials."
    exit 1
fi

mysqldump --defaults-extra-file=/root/.mysql.cnf "$DB_NAME_MAIN" > "$BACKUP_DIR/${MAINDOMAIN}_db_${TIMESTAMP}.sql"

echo "✅ Backup saved to $BACKUP_DIR"

# --- STEP 2: MIGRATE FILES ---

echo "📂 Syncing files (Staging -> Production)..."
# We use rsync with --delete to make Production an exact copy of Staging.
# We EXCLUDE wp-config.php so we keep Production's DB connection details.
rsync -a --delete --exclude 'wp-config.php' "$SUB_ROOT/" "$MAIN_ROOT/"

# --- STEP 3: MIGRATE DATABASE ---

echo "🗄️  Migrating Database..."

# Get Staging DB Name
DB_NAME_SUB=$(wp config get DB_NAME --path="$SUB_ROOT" --allow-root)

# Dump Staging DB to temp file
TEMP_DUMP="/tmp/${SUBDOMAIN}_migration.sql"
mysqldump --defaults-extra-file=/root/.mysql.cnf "$DB_NAME_SUB" > "$TEMP_DUMP"

# Import Staging DB into Production DB (Overwriting it)
mysql --defaults-extra-file=/root/.mysql.cnf "$DB_NAME_MAIN" < "$TEMP_DUMP"
rm "$TEMP_DUMP"

# --- STEP 4: SEARCH & REPLACE ---

echo "🔄 Updating URLs in Production Database..."

# Run Search-Replace on PRODUCTION path
# Note: We run as root (--allow-root) but on the production files
wp search-replace "https://$SUBDOMAIN" "https://$MAINDOMAIN" --path="$MAIN_ROOT" --skip-columns=guid --allow-root
wp search-replace "http://$SUBDOMAIN" "http://$MAINDOMAIN" --path="$MAIN_ROOT" --skip-columns=guid --allow-root

echo "🧹 Flushing Object Cache..."
wp cache flush --path="$MAIN_ROOT" --allow-root

# --- STEP 5: PERMISSIONS & CLEANUP ---

echo "🔒 Fixing File Permissions..."
# CRITICAL: Give ownership back to the user, or they can't edit files
chown -R "$USER:$USER" "$MAIN_ROOT"

# Restart PHP safely (Detect version automatically)
echo "🔄 Reloading PHP-FPM..."
# Find the PHP version used by the domain in Hestia config, defaults to system default if not found
PHP_VER=$(v-list-web-domain "$USER" "$MAINDOMAIN" json | grep "BACKEND_VERSION" | cut -d'"' -f4 | sed 's/PHP-//')
if [ -n "$PHP_VER" ]; then
    systemctl reload "php$PHP_VER-fpm"
else
    # Fallback to common versions if detection fails
    systemctl reload php*-fpm 2>/dev/null
fi

echo "✅ SUCCESS! $SUBDOMAIN has been pushed to https://$MAINDOMAIN"