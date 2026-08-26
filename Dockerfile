FROM alpine:latest

# Install Apache, MariaDB, PHP 8.3 FPM, FFmpeg, ImageMagick, Supervisor, and dependencies
RUN apk update && \
    apk add --no-cache \
    bash \
    shadow \
    supervisor \
    apache2 \
    apache2-proxy \
    mariadb \
    mariadb-client \
    php83 \
    php83-fpm \
    php83-mysqli \
    php83-pdo_mysql \
    php83-curl \
    php83-dom \
    php83-gd \
    php83-mbstring \
    php83-xml \
    php83-zip \
    php83-session \
    php83-sqlite3 \
    php83-pdo_sqlite \
    imagemagick \
    ffmpeg \
    tzdata \
    curl \
    wget \
    libc6-compat

# Download official Cloudflare Tunnel binary
RUN wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/bin/cloudflared && \
    chmod +x /usr/bin/cloudflared

# Enable IP pass-through, FastCGI Proxy, and switch to the modern Event MPM
RUN sed -i 's/^LoadModule mpm_prefork_module/#LoadModule mpm_prefork_module/g' /etc/apache2/httpd.conf && \
    sed -i 's/^#LoadModule mpm_event_module/LoadModule mpm_event_module/g' /etc/apache2/httpd.conf && \
    sed -i '/LoadModule remoteip_module/s/^#//g' /etc/apache2/httpd.conf && \
    echo "RemoteIPHeader CF-Connecting-IP" >> /etc/apache2/httpd.conf && \
    sed -i 's/%h/%a/g' /etc/apache2/httpd.conf && \
    sed -i '/LoadModule proxy_module/s/^#//g' /etc/apache2/httpd.conf && \
    sed -i '/LoadModule proxy_fcgi_module/s/^#//g' /etc/apache2/httpd.conf && \
    echo "<FilesMatch \.php$>" >> /etc/apache2/httpd.conf && \
    echo "    SetHandler \"proxy:fcgi://127.0.0.1:9000\"" >> /etc/apache2/httpd.conf && \
    echo "</FilesMatch>" >> /etc/apache2/httpd.conf

# Create necessary directories and tell Apache to load domain configs from the volume
RUN mkdir -p /run/mysqld && chown -R mysql:mysql /run/mysqld && \
    mkdir -p /config/apache-domains && \
    echo "IncludeOptional /config/apache-domains/*.conf" >> /etc/apache2/httpd.conf

# Copy configuration and startup scripts
COPY supervisord.conf /etc/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose HTTP and MySQL ports
#EXPOSE 80 3306

# Declare volumes
VOLUME ["/var/lib/mysql", "/var/www", "/config"]

ENTRYPOINT ["/entrypoint.sh"]
