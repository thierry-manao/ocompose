# Docker Override System for ocompose Instances

This directory contains Docker configuration overrides for this specific instance.

## Structure

```
instances/<name>/
├── docker-compose.override.yml  # Docker Compose overrides
└── docker/
    ├── config/                   # CodeIgniter 3 config overrides
    │   ├── database.php         # Main app database config
    │   ├── config.php           # Main app config
    │   ├── api-database.php     # API database config
    │   └── api-config.php       # API config
    └── nginx/
        └── default.conf         # Custom nginx configuration
```

## How It Works

1. **docker-compose.override.yml** - Automatically merged with the main docker-compose.yml when starting the instance
   - Add extra volumes
   - Override environment variables
   - Change port mappings
   - Add extra services

2. **docker/config/** - Override PHP/CodeIgniter configurations
   - Files are mounted into the container at runtime
   - Use environment variables (DB_HOST, DB_PORT, etc.) for dynamic values
   - Separate configs for main app and API

3. **docker/nginx/** - Custom nginx configuration
   - Override default nginx behavior
   - Support dual-port setup (main app + API)
   - Custom routing rules

## Usage

### Basic Override

Just create `docker-compose.override.yml` in your instance directory:

```yaml
services:
  php:
    volumes:
      - ./docker/config/database.php:/var/www/html/application/config/development/database.php
```

### Custom Nginx Config

1. Create `docker/nginx/default.conf`
2. Add volume mount in `docker-compose.override.yml`:

```yaml
services:
  nginx:
    volumes:
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
```

### Environment Variables Available in PHP Configs

All environment variables from `.env` are available via `getenv()`:

- `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USER`, `DB_PASSWORD`
- `APP_BASE_URL`, `CI3_SESSION_SAVE_PATH`, `CI3_ENCRYPTION_KEY`
- Custom variables you add to `.env`

Example in `database.php`:
```php
'hostname' => getenv('DB_HOST') ?: 'host.docker.internal',
'port'     => getenv('DB_PORT') ?: '23306',
```

## Best Practices

1. **Use environment variables** - Don't hardcode values, use `getenv()`
2. **Keep overrides minimal** - Only override what's necessary
3. **Document your changes** - Add comments explaining why you're overriding
4. **Test in isolation** - Restart the instance after making changes
5. **Version control** - Commit override files with your instance config

## Environment-Specific Overrides

The PHP config overrides mount to `application/config/development/` which means they only apply when `CI_ENV=development` (Docker default). This prevents accidental override in production.

## Restart After Changes

After modifying override files:
```bash
./ocompose <instance> restart
```

Or from the Web UI: click "Restart" button.
