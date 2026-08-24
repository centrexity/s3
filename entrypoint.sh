#!/bin/bash
set -e

# Ensure permissions are correct on mount points
chown -R mysql:mysql /var/lib/mysql
chown -R apache:apache /var/www/localhost/htdocs

# Create config directories if they don't exist
mkdir -p /config/apache-domains
mkdir -p /config/cloudflared

# Initialize MariaDB data directory if it is completely empty
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "Initializing MariaDB database..."
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql
fi

# Provide a default Apache config if the mapped directory is empty
if [ -z "$(ls -A /config/apache-domains)" ]; then
    echo "No custom domains found. Creating default VirtualHost..."
    cat << 'EOF' > /config/apache-domains/000-default.conf
<VirtualHost *:80>
    DocumentRoot "/var/www/localhost/htdocs"
    ServerName localhost
    
    <Directory "/var/www/localhost/htdocs">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
fi

# Generate placeholder Cloudflare token file if one doesn't exist
TOKEN_FILE="/config/cloudflared/token.txt"
if [ ! -f "$TOKEN_FILE" ]; then
    echo "YOUR_CLOUDFLARE_TOKEN_HERE" > "$TOKEN_FILE"
    echo "WARNING: $TOKEN_FILE was created. Please replace its contents with your actual tunnel token."
fi

# Create a launcher script for Cloudflared that reads the token dynamically
cat << 'EOF' > /usr/local/bin/run-cloudflared.sh
#!/bin/bash
TOKEN=$(cat /config/cloudflared/token.txt | tr -d '\n\r ')
if [ "$TOKEN" != "YOUR_CLOUDFLARE_TOKEN_HERE" ] && [ -n "$TOKEN" ]; then
    echo "Starting Cloudflare Tunnel..."
    exec /usr/bin/cloudflared tunnel --no-autoupdate run --token "$TOKEN"
else
    echo "Cloudflare token not set in /config/cloudflared/token.txt. Sleeping..."
    sleep 60
    exit 1
fi
EOF
chmod +x /usr/local/bin/run-cloudflared.sh

# Launch Supervisor to manage Apache, MariaDB, Cron, and Cloudflared
exec /usr/bin/supervisord -n -c /etc/supervisord.conf
