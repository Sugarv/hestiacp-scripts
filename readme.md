# HestiaCP WordPress Management Scripts

This repository provides Bash scripts for managing WordPress sites within a HestiaCP environment. They utilize `WP-CLI` for serialization-safe database operations, crucial for maintaining data integrity during URL changes.

## Scripts

### [`sub_2_main.sh`](sub_2_main.sh)

Migrates a WordPress installation from a subdomain to its main domain. It handles file transfers, safely updates database URLs using `wp search-replace`, clears WP-CLI cache, and restarts web services. Requires HestiaCP username and subdomain.

**Usage:**
```bash
./sub_2_main.sh
```

### [`create_subdomain.sh`](create_subdomain.sh)

Clones an existing WordPress site to a new subdomain. This is useful for testing or staging. The script dumps the original database, creates a new one for the subdomain, copies files, updates `wp-config.php`, and performs serialization-safe URL replacements using `wp search-replace`. Requires HestiaCP username and desired subdomain URL.

**Usage:**
```bash
./create_subdomain.sh <username> <desired-subdomain-url>
```

### [`copy_domain.sh`](copy_domain.sh)

Copies an existing WordPress site from one domain to another under the same HestiaCP user. It handles database dumping and importing, file copying, `wp-config.php` updates, and serialization-safe URL replacements via `wp search-replace`. Requires HestiaCP username, source domain, and destination domain.

**Usage:**
```bash
./copy_domain.sh <username> <source-domain> <destination-domain>
```

## Requirements

*   **HestiaCP:** Designed for HestiaCP environments.
*   **WP-CLI:** Essential for safe database operations. Install from [https://wp-cli.org/#install](https://wp-cli.org/#install) if not present.
*   **MySQL Root Credentials:** Required for `create_subdomain.sh` and `copy_domain.sh` via `/root/.mysql.cnf`.