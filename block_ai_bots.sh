#!/bin/bash

# The text block to be added
BLOCK="# Block AI & Scraping Bots
User-agent: GPTBot
Disallow: /
User-agent: ChatGPT-User
Disallow: /
User-agent: ClaudeBot
Disallow: /
User-agent: anthropic-ai
Disallow: /
User-agent: Omgilibot
Disallow: /
User-agent: Omgili
Disallow: /
User-agent: FacebookBot
Disallow: /
User-agent: Bytespider
Disallow: /
User-agent: CCBot
Disallow: /
User-agent: Diffbot
Disallow: /
User-agent: Amazonbot
Disallow: /"

echo "Starting to update robots.txt files..."
echo "------------------------------------------------"

# Find all public_html directories in HestiaCP
for public_html in /home/*/web/*/public_html; do
    # Check if the directory actually exists
    if [ -d "$public_html" ]; then
        
        # Extract the username from the path (the 3rd field in /home/username/...)
        user=$(echo "$public_html" | cut -d'/' -f3)
        robots_file="$public_html/robots.txt"

        echo -n "Checking: $robots_file ... "

        # If the file doesn't exist, create it with basic default rules
        if [ ! -f "$robots_file" ]; then
            echo -e "User-agent: *\nAllow: /\n" > "$robots_file"
            chown "$user:$user" "$robots_file"
            echo -n "[Created] "
        fi

        # Check if our custom AI block is already in the file
        if grep -q "# Block AI & Scraping Bots" "$robots_file"; then
            echo "[Already exists - Skipping]"
        else
            # Append the block with a leading newline for clean formatting
            echo -e "\n$BLOCK" >> "$robots_file"
            chown "$user:$user" "$robots_file" # Ensure correct permissions
            echo "[Added successfully!]"
        fi
    fi
done

echo "------------------------------------------------"
echo "Process completed!"
