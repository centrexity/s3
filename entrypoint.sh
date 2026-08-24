#!/bin/bash
set -e


# ==========================================
# 1. UNRAID PERMISSIONS (SMB COMPATIBILITY)
# ==========================================
PUID=${PUID:-99}
PGID=${PGID:-100}

# Modify Apache user
groupmod -o -g "$PGID" apache
usermod -o -u "$PUID" apache

# Modify MySQL user and ensure runtime socket folder exists with correct permissions
groupmod -o -g "$PGID" mysql 2>/dev/null || groupadd -g "$PGID" mysql
usermod -o -u "$PUID" -g "$PGID" mysql 2>/dev/null || usermod -u "$PUID" -g "$PGID" mysql

mkdir -p /run/mysqld
chown -R mysql:mysql /run/mysqld
chmod 775 /run/mysqld

# Ensure permissions on database mount points
chown -R mysql:mysql /var/lib/mysql

# ==========================================
# 2. APACHE DIRECTORY STRUCTURE & SYMLINKS
# ==========================================
mkdir -p /var/www/localhost/htdocs

# Restore Alpine's Apache system shortcuts
ln -sfn /usr/lib/apache2 /var/www/modules
ln -sfn /var/log/apache2 /var/www/logs
ln -sfn /run/apache2 /var/www/run

# Create config directories if they don't exist
mkdir -p /config/apache-domains
mkdir -p /config/cloudflared
mkdir -p /config/mysql-conf

# Automatically ensure htdocs and log directories exist for ANY domain config present
for domain_conf in /config/apache-domains/*.conf; do
    if [ -f "$domain_conf" ]; then
        # Extract DocumentRoot path from the conf file, or fall back to standard naming
        DOM_ROOT=$(grep -i "DocumentRoot" "$domain_conf" | awk '{print $2}' | tr -d '"')
        if [ -n "$DOM_ROOT" ]; then
            mkdir -p "$DOM_ROOT"
            mkdir -p "$(dirname "$DOM_ROOT")/logs"
        fi
    fi
done

chown -R apache:apache /var/www
find /var/www -type d -exec chmod 755 {} \;
find /var/www -type f -exec chmod 664 {} \;




# Create config directories if they don't exist
mkdir -p /config/apache-domains
mkdir -p /config/cloudflared
mkdir -p /config/mysql-conf


# Force PHP-FPM to run as the 'apache' user instead of 'nobody'
sed -i 's/user = nobody/user = apache/g' /etc/php83/php-fpm.d/www.conf
sed -i 's/group = nobody/group = apache/g' /etc/php83/php-fpm.d/www.conf
# Sometimes Alpine defaults them to 'www-data', so let's handle that too just in case
sed -i 's/user = www-data/user = apache/g' /etc/php83/php-fpm.d/www.conf
sed -i 's/group = www-data/group = apache/g' /etc/php83/php-fpm.d/www.conf


# ==========================================
# 3. GLOBAL HARDENING: APACHE & PHP
# ==========================================
# Ensure Apache's headers, rewrite, and proxy modules are enabled
sed -i '/LoadModule headers_module/s/^#//g' /etc/apache2/httpd.conf
sed -i '/LoadModule rewrite_module/s/^#//g' /etc/apache2/httpd.conf

# Generate Global Apache Security Config
cat << 'EOF' > /etc/apache2/conf.d/00-global-security.conf
# Mask Server Identity
ServerTokens Prod
ServerSignature Off

# Disable Cross-Site Tracing
TraceEnable Off

# Inject Global Security Headers
<IfModule mod_headers.h>
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


# Generate Global PHP Security & Upload Config
cat << 'EOF' > /etc/php83/conf.d/99-global-hardening.ini
; Hide PHP version from HTTP headers
expose_php = Off

; Disable dangerous OS execution functions (leaving 'exec' intact for FFmpeg)
;disable_functions = system, shell_exec, passthru, popen

; 100MB Upload Limits & Timeouts
file_uploads = On
upload_max_filesize = 100M
post_max_size = 100M
memory_limit = 256M
max_execution_time = 300
max_input_time = 300
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

# Automatically ensure log directories exist for any custom domain structure
for domain_dir in /var/www/*/; do
    if [ -d "${domain_dir}htdocs" ]; then
        mkdir -p "${domain_dir}logs"
        chown -R apache:apache "${domain_dir}logs"
    fi
done

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
