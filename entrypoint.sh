#!/bin/bash
set -e

# ==========================================
# 1. UNRAID PERMISSIONS (SMB COMPATIBILITY)
# ==========================================
# Default to Unraid's standard IDs (99:100) if variables are not passed
PUID=${PUID:-99}
PGID=${PGID:-100}

# Modify the internal apache user to match Unraid's SMB user
echo "Setting Apache user to PUID: $PUID and PGID: $PGID"
groupmod -o -g "$PGID" apache
usermod -o -u "$PUID" apache

# Ensure permissions are correct on database mount points
chown -R mysql:mysql /var/lib/mysql

# ==========================================
# 2. APACHE DIRECTORY STRUCTURE & SYMLINKS
# ==========================================
# Ensure the default localhost directory exists to prevent Apache crashes
mkdir -p /var/www/localhost/htdocs

# Restore Alpine's Apache system shortcuts masked by the Unraid volume
ln -sfn /usr/lib/apache2 /var/www/modules
ln -sfn /var/log/apache2 /var/www/logs
ln -sfn /run/apache2 /var/www/run

# Ensure permissions are correct across all hosted domains
chown -R apache:apache /var/www

# Create config directories if they don't exist
mkdir -p /config/apache-domains
mkdir -p /config/cloudflared
mkdir -p /config/mysql-conf

# ==========================================
# 3. GLOBAL HARDENING: APACHE & PHP
# ==========================================
# Ensure Apache's headers module is enabled
sed -i '/LoadModule headers_module/s/^#//g' /etc/apache2/httpd.conf

# Generate Global Apache Security Config
cat << 'EOF' > /etc/apache2/conf.d/00-global-security.conf
# Mask Server Identity
ServerTokens Prod
ServerSignature Off

# Disable Cross-Site Tracing
TraceEnable Off

# Inject Global Security Headers
<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
</IfModule>

# Globally block hidden files and directories (e.g., .env, .git)
<DirectoryMatch "/^\.|\/\.">
    Require all denied
</DirectoryMatch>

# Globally block sensitive file extensions
<FilesMatch "\.(bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist)$">
    Require all denied
</FilesMatch>
EOF

# Generate Global PHP Security Config
cat << 'EOF' > /etc/php83/conf.d/99-global-hardening.ini
; Hide PHP version from HTTP headers
expose_php = Off

; Disable dangerous OS execution functions (leaving 'exec' intact for FFmpeg)
disable_functions = system, shell_exec, passthru, popen
EOF

# ==========================================
# 4. INITIALIZATION (MARIADB, APACHE, TUNNEL)
# ==========================================
# Initialize MariaDB data directory if it is completely empty
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "Initializing MariaDB database..."
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql
fi

# Generate a blank custom MariaDB config if one doesn't exist
if [ ! -f "/config/mysql-conf/custom.cnf" ]; then
    echo "[mysqld]" > /config/mysql-conf/custom.cnf
    echo "# Add your custom MariaDB settings here" >> /config/mysql-conf/custom.cnf
fi

# Tell MariaDB to load any custom configs from the volume
if ! grep -q "!includedir /config/mysql-conf" /etc/my.cnf.d/mariadb-server.cnf; then
    echo "!includedir /config/mysql-conf" >> /etc/my.cnf.d/mariadb-server.cnf
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

# ==========================================
# 5. LAUNCH SUPERVISOR
# ==========================================
# Launch Supervisor to manage Apache, MariaDB, Cron, PHP-FPM, and Cloudflared
exec /usr/bin/supervisord -n -c /etc/supervisord.conf
