

Unraid Web GUI (No XML needed)
You can fill out the native Unraid Docker form directly:1.Open the Add Container form:Go to the Docker tab in Unraid and click Add Container at the bottom.2.Fill in basic container details:Set the following fields:Name: centrexity-s3Repository: ghcr.io/centrexity/s3:mainNetwork Type: bridge(Leave all port mappings blank/deleted).3.Add volume paths:Click Add another Path, Port, Variable, Device or Extra Parameter 3 times to map the storage:Path 1 (Config):Name: ConfigContainer Path: /configHost Path: /mnt/user/appdata/centrexity-s3/configPath 2 (Web Root):Name: Web FilesContainer Path: /var/www/localhost/htdocsHost Path: /mnt/user/appdata/centrexity-s3/wwwPath 3 (Database):Name: MySQL DataContainer Path: /var/lib/mysqlHost Path: /mnt/user/appdata/centrexity-s3/mysql4.Deploy:Click Apply. Unraid saves its own local configuration and starts the container.


## Separate PHP-FPM pools

The image loads additional pools from `/config/php-fpm/pools.d/*.conf`.
These files and slow logs under `/config/php-fpm/logs/` persist in the existing
`/config` volume. Startup recreates `/run/php-fpm/` for runtime sockets.
Existing pool files and Apache domain configurations are not rewritten.
The default `www` pool and global Apache handler on port 9000 remain available.

Examples are shipped in `/usr/share/s3/examples/` (also in this repo's `examples/`).
To migrate zagd.com after deploying the image:

1. Copy `php-fpm-site.conf.example` to `/config/php-fpm/pools.d/zagd.conf`.
2. In `/config/apache-domains/zagd.com.conf`, replace the existing PHP
   `<FilesMatch>` handler with the contents shown in
   `apache-php-handler.conf.example`. Preserve the rest of the virtual host.
3. Check both configurations with `php-fpm83 -t` and `httpd -t`, then restart
   the container during a maintenance window.
4. Check PHP responses on zagd.com and an unmigrated site. Check the PHP-FPM
   error log for startup or slow-log permission errors.

For each additional site, choose a unique pool name, socket path and slow-log
path, and point its Apache handler at that exact socket. Adding a pool alone
does not route any traffic to it. Sites without an explicit PHP handler continue
using the global handler; sites with one keep their configured handler.

The example uses on-demand workers with a limit of three. This is a starting
example, not a measured capacity recommendation. Worker limits add up across
all pools, including the default pool. Budget their combined memory and database
load before increasing limits. Slow logging diagnoses slow requests; it does not
terminate them or accelerate queries. Pool isolation does not isolate shared
CPU, storage or database capacity.

Supervisor exclusively manages cron; the entrypoint only creates its schedule.

Before releasing the image, verify legacy PHP routing, two independently routed
pools, bounded worker exhaustion in one pool while the other responds, restart
and recreation persistence, and one cron daemon executing each job once.
