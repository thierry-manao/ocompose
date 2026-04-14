# Docker Override System

ocompose supports per-instance Docker configuration overrides, allowing you to customize containers without modifying the main docker-compose.yml.

## Quick Start

Each instance can have its own `docker-compose.override.yml` file that extends/overrides the base configuration:

```bash
# Copy the template
cp templates/docker-compose.override.yml instances/<name>/

# Copy config templates (optional)
cp -r templates/docker/ instances/<name>/

# Edit as needed
nano instances/<name>/docker-compose.override.yml

# Restart to apply
./ocompose <name> restart
```

## Directory Structure

```
instances/<name>/
├── .env
├── docker-compose.override.yml   # Auto-merged with main compose file
├── docker/                        # Custom configs
│   ├── config/                    # PHP/CI3 config overrides
│   │   ├── database.php          # Main app database
│   │   ├── config.php            # Main app config
│   │   ├── api-database.php      # API database
│   │   └── api-config.php        # API config
│   └── nginx/
│       └── default.conf          # Custom nginx config
└── www/                          # Application code
```

## Use Cases

### Override CodeIgniter 3 Config

Mount custom config files that use environment variables:

**docker-compose.override.yml:**
```yaml
services:
  php:
    volumes:
      - ./docker/config/database.php:/var/www/html/application/config/development/database.php
      - ./docker/config/config.php:/var/www/html/application/config/development/config.php
```

**docker/config/database.php:**
```php
<?php
$db['default'] = array(
    'hostname' => getenv('DB_HOST') ?: 'host.docker.internal',
    'port'     => getenv('DB_PORT') ?: '23306',
    'database' => getenv('DB_DATABASE') ?: '',
    // ... more config
);
```

### Custom Nginx Configuration

**docker-compose.override.yml:**
```yaml
services:
  nginx:
    ports:
      - "8000:80"    # Main app
      - "8001:81"    # API on separate port
    volumes:
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
```

**docker/nginx/default.conf:**
```nginx
server {
    listen 80;
    root /var/www/html/public;
    # ... main app config
}

server {
    listen 81;
    root /var/www/html/api/public;
    # ... API config
}
```

### Add Development Tools

```yaml
services:
  mailhog:
    image: mailhog/mailhog
    ports:
      - "8025:8025"  # Web UI
      - "1025:1025"  # SMTP
    networks:
      - net
```

### Override Environment Variables

```yaml
services:
  php:
    environment:
      PHP_MEMORY_LIMIT: 512M
      CI3_ENCRYPTION_KEY: "your-secret-key-here"
      CUSTOM_API_URL: "https://api.example.com"
```

### Mount Additional Volumes

```yaml
services:
  php:
    volumes:
      - ./docker/uploads:/var/www/html/uploads
      - ./docker/cache:/var/www/html/application/cache
```

## Templates

Templates are available in `templates/`:

- `docker-compose.override.yml` - Base override template with examples
- `docker/config/*.php` - CodeIgniter 3 config templates using `getenv()`
- `docker/nginx/default.conf` - Dual-port nginx config (main + API)
- `docker/README.md` - Documentation

## Environment Variables in Configs

All `.env` variables are available to PHP via `getenv()`:

```php
// In docker/config/database.php
'hostname' => getenv('DB_HOST') ?: 'localhost',
'port'     => getenv('DB_PORT') ?: '3306',
'username' => getenv('DB_USER') ?: 'root',
'password' => getenv('DB_PASSWORD') ?: '',
'database' => getenv('DB_DATABASE') ?: '',
```

Common variables from `.env`:
- `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USER`, `DB_PASSWORD`
- `APP_BASE_URL`, `PROJECT_NAME`
- `CI3_SESSION_SAVE_PATH`, `CI3_ENCRYPTION_KEY`, `CI3_AUTH_URL`

## How It Works

1. **Base Configuration** - Main `docker-compose.yml` defines services
2. **Instance Override** - If `instances/<name>/docker-compose.override.yml` exists, it's automatically merged
3. **Docker Compose Merge** - Docker Compose combines both files using standard merge behavior
4. **Volume Mounts** - Custom configs are mounted as read-only volumes

The merge command executed:
```bash
docker compose \
  -f docker-compose.yml \
  -f instances/<name>/docker-compose.override.yml \
  --env-file instances/<name>/.env \
  up
```

## Best Practices

1. **Use Environment Variables** - Don't hardcode values in config files
2. **Keep Overrides Minimal** - Only override what's necessary
3. **Document Changes** - Add comments explaining why you're overriding
4. **Test Individually** - Restart instance after changes: `./ocompose <name> restart`
5. **Version Control** - Commit override files (but not `.env` with secrets!)
6. **Read-Only Mounts** - Use `:ro` for config files to prevent accidental modification

## Debugging

View the merged configuration:
```bash
cd instances/<name>
docker compose \
  -f ../../docker-compose.yml \
  -f docker-compose.override.yml \
  --env-file .env \
  config
```

Check mounted volumes in running container:
```bash
docker inspect test_php | grep -A 20 Mounts
```

## See Also

- [Docker Compose Override Documentation](https://docs.docker.com/compose/multiple-compose-files/merge/)
- `templates/docker/README.md` - More detailed examples
- `instances/test/` - Working example instance with overrides
