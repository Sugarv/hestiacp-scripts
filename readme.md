# HestiaCP WordPress Management Scripts

This repository contains a set of Bash scripts designed to assist with common WordPress management tasks within a HestiaCP environment. These scripts leverage `WP-CLI` to ensure safe and serialization-aware operations, particularly when dealing with URL changes in the WordPress database.

## Scripts

### [`sub_2_main.sh`](sub_2_main.sh)

This script facilitates the migration of a WordPress installation from a subdomain to its main domain. It handles file transfers and safely updates database URLs using `WP-CLI`'s serialization-aware `search-replace` command, preventing data corruption.

**Key Features:**
*   Prompts for HestiaCP username and subdomain.
*   Extracts main domain from the provided subdomain.
*   Verifies `wp-config.php` existence.
*   Backs up main domain files and database.
*   Moves WordPress files from the subdomain's `public_html` to the main domain's `public_html`.
*   Updates database URLs using `wp search-replace` (serialization-safe).
*   Clears WP-CLI cache.
*   Restarts Nginx, Apache2, and PHP-FPM services.
*   Includes a check for `WP-CLI` availability at the beginning of the script.

**Usage:**
```bash
./sub_2_main.sh
```

### [`create_subdomain.sh`](create_subdomain.sh)

This script creates a clone of an existing WordPress site on a new subdomain. It's useful for setting up testing environments, staging sites, or preparing for migrations. The script ensures that the cloned site's database URLs are correctly updated using `WP-CLI`'s serialization-aware `search-replace` command.

**Key Features:**
*   Requires HestiaCP username and desired subdomain URL as arguments.
*   Checks for `WP-CLI` availability at the beginning of the script.
*   Adds the new subdomain using `v-add-web-domain`.
*   Extracts database details from the original WordPress site's `wp-config.php`.
*   Dumps the original database.
*   Creates a new staging database for the subdomain.
*   Imports the original database dump into the new staging database.
*   Copies WordPress files from the main domain to the new subdomain's `public_html`.
*   Updates the `wp-config.php` file for the new subdomain to point to its dedicated database.
*   Updates database URLs within the new subdomain's database using `wp search-replace` (serialization-safe).
*   Clears WP-CLI cache.
*   Cleans up temporary SQL dump files.

**Usage:**
```bash
./create_subdomain.sh <username> <desired-subdomain-url>
```

### [`copy_domain.sh`](copy_domain.sh)

This script copies an existing WordPress site from one domain to another within the same HestiaCP user account. It ensures that all files are transferred and that database URLs are updated correctly and safely using `WP-CLI`'s serialization-aware `search-replace` command.

**Key Features:**
*   Requires HestiaCP username, source domain, and destination domain as arguments.
*   Checks for `WP-CLI` availability at the beginning of the script.
*   Adds the new destination domain using `v-add-web-domain`.
*   Verifies the existence of the source domain's `wp-config.php`.
*   Extracts database details from the source WordPress site's `wp-config.php`.
*   Dumps the source database.
*   Creates a new database for the destination domain.
*   Imports the source database dump into the new destination database.
*   Copies WordPress files from the source domain's `public_html` to the destination domain's `public_html`.
*   Updates the `wp-config.php` file for the destination domain to point to its dedicated database.
*   Updates database URLs within the new destination domain's database using `wp search-replace` (serialization-safe).
*   Clears WP-CLI cache.
*   Cleans up temporary SQL dump files.

**Usage:**
```bash
./copy_domain.sh <username> <source-domain> <destination-domain>
```

## Requirements

*   **HestiaCP:** These scripts are designed for use with HestiaCP.
*   **WP-CLI:** The scripts heavily rely on `WP-CLI` for safe database operations. Ensure `WP-CLI` is installed and accessible in your system's PATH. If not, you can download it from [https://wp-cli.org/#install](https://wp-cli.org/#install).
*   **MySQL Root Credentials:** The `create_subdomain.sh` and `copy_domain.sh` scripts require access to MySQL root credentials via `/root/.mysql.cnf`.