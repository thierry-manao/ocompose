# Docker Compose Override Examples

This document provides complete examples for common override patterns based on existing projects.

---

## Example 1: Identification2023-style Setup

**Project characteristics:**
- CodeIgniter 3 application with webservice
- Single set of configs shared by main app and webservice
- PHP 7.4
- Custom session path: `/var/www/compte/sessions`
- Port: 38080

**File: `instances/myidentification/docker-compose.override.yml`**

```yaml
services:
  php:
    volumes:
      # Main app configs
      - ./instances/${PROJECT_NAME}/docker/config/database.php:/var/www/html/application/config/development/database.php
      - ./instances/${PROJECT_NAME}/docker/config/config.php:/var/www/html/application/config/development/config.php
      - ./instances/${PROJECT_NAME}/docker/config/constants.php:/var/www/html/application/config/development/constants.php
      # Webservice configs (reuse same files)
      - ./instances/${PROJECT_NAME}/docker/config/database.php:/var/www/html/webservice/v1/application/config/development/database.php
      # Session volume
      - sessions:/var/www/compte/sessions
      # Writable volumes (prevents permission errors)
      - app-logs:/var/www/html/application/logs
      - app-cache:/var/www/html/application/cache
      - webservice-logs:/var/www/html/webservice/v1/application/logs
    networks:
      - net
      - dbserver

  nginx:
    volumes:
      - ./instances/${PROJECT_NAME}/docker/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    ports:
      - "${NGINX_HTTP_PORT:-38080}:80"
    networks:
      - net
      - dbserver

volumes:
  sessions:
  app-logs:
  app-cache:
  webservice-logs:

networks:
  dbserver:
    external: true
    name: dbserver_licences_default
```

**Note:** The `sessions` volume will be automatically namespaced as `myidentification_sessions` by Docker Compose.

**Important:** The writable volumes (`app-logs`, `app-cache`, `webservice-logs`) are essential to prevent permission errors. When you mount `.:/var/www/html` from the host, the log and cache directories inherit host permissions. Since PHP-FPM runs as `www-data`, it can't write to these directories, causing `chmod()` errors. Named volumes solve this by letting Docker create directories with correct ownership.

**Required config files in `instances/myidentification/docker/config/`:**
- `database.php` ← DB connection (host.docker.internal:23306)
- `config.php` ← Base URL, session settings
- `constants.php` ← App constants

---

## Example 2: Compta2022-style Setup

**Project characteristics:**
- CodeIgniter 3 application with separate API
- Main app and API have separate config files
- PHP 5.6
- Custom session path: `/var/www/compta/session`
- Port: 38081

**File: `instances/mycompta/docker-compose.override.yml`**

```yaml
services:
  php:
    volumes:
      # Main app configs
      - ./instances/${PROJECT_NAME}/docker/config/database.php:/var/www/html/application/config/development/database.php
      - ./instances/${PROJECT_NAME}/docker/config/config.php:/var/www/html/application/config/development/config.php
      - ./instances/${PROJECT_NAME}/docker/config/constants.php:/var/www/html/application/config/development/constants.php
      # API configs (separate files)
      - ./instances/${PROJECT_NAME}/docker/config/api-database.php:/var/www/html/api/application/config/development/database.php
      - ./instances/${PROJECT_NAME}/docker/config/api-config.php:/var/www/html/api/application/config/development/config.php
      - ./instances/${PROJECT_NAME}/docker/config/api-constants.php:/var/www/html/api/application/config/development/constants.php
      # Session volume
      - sessions:/var/www/compta/session
      # Writable volumes (prevents permission errors)
      - app-logs:/var/www/html/application/logs
      - app-cache:/var/www/html/application/cache
      - api-logs:/var/www/html/api/application/logs
    networks:
      - net
      - dbserver

  nginx:
    volumes:
      - ./instances/${PROJECT_NAME}/docker/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    ports:
      - "${NGINX_HTTP_PORT:-38081}:80"
    networks:
      - net
      - dbserver

volumes:
  sessions:
  app-logs:
  app-cache:
  api-logs:

networks:
  dbserver:
    external: true
    name: dbserver_licences_default
```

**Note:** The `sessions` volume will be automatically namespaced as `mycompta_sessions` by Docker Compose.

**Important:** Writable volumes for logs and cache prevent permission errors. See the note in Example 1 for details.

**Required config files in `instances/mycompta/docker/config/`:**
- `database.php` ← Main app DB connection
- `config.php` ← Main app config
- `constants.php` ← Main app constants
- `api-database.php` ← API DB connection
- `api-config.php` ← API config
- `api-constants.php` ← API constants

---

## Example 3: Simple Single-App Setup

**Project characteristics:**
- Single CodeIgniter 3 application
- No separate API or webservice
- Standard session handling
- Port: 8080

**File: `instances/mysimpleapp/docker-compose.override.yml`**

```yaml
services:
  php:
    volumes:
      - ./instances/${PROJECT_NAME}/docker/config/database.php:/var/www/html/application/config/development/database.php
      - ./instances/${PROJECT_NAME}/docker/config/config.php:/var/www/html/application/config/development/config.php
      - ./instances/${PROJECT_NAME}/docker/config/constants.php:/var/www/html/application/config/development/constants.php
    networks:
      - net
      - dbserver

  nginx:
    volumes:
      - ./instances/${PROJECT_NAME}/docker/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    ports:
      - "${NGINX_HTTP_PORT:-8080}:80"
    networks:
      - net
      - dbserver

networks:
  dbserver:
    external: true
    name: dbserver_licences_default
```

---

## Example 4: With Additional Services (MailHog)

Add email testing capability to any setup:

```yaml
services:
  php:
    volumes:
      - ./instances/${PROJECT_NAME}/docker/config/database.php:/var/www/html/application/config/development/database.php
      - ./instances/${PROJECT_NAME}/docker/config/config.php:/var/www/html/application/config/development/config.php
    networks:
      - net

  nginx:
    ports:
      - "${NGINX_HTTP_PORT:-8080}:80"

  mailhog:
    image: mailhog/mailhog:latest
    container_name: ${PROJECT_NAME}_mailhog
    ports:
      - "${MAILHOG_UI_PORT:-8025}:8025"    # Web UI
      - "${MAILHOG_SMTP_PORT:-1025}:1025"  # SMTP
    networks:
      - net
```

Then configure your PHP app to use `mailhog:1025` as SMTP server.

---

## Common Patterns

### Connecting to db-docker-server

All examples above assume you're using the external `db-docker-server` setup. This requires:

1. **Add the external network** to your override:
```yaml
networks:
  dbserver:
    external: true
    name: dbserver_licences_default
```

2. **Connect services** to the network:
```yaml
services:
  php:
    networks:
      - net
      - dbserver
```

3. **Configure DB connection** in your config files:
   - Host: `host.docker.internal` or the db-docker-server container name
   - Port: `23306` (or your db-docker-server port)

### Custom Session Paths

If your Dockerfile creates a custom session directory (like `/var/www/compte/sessions` or `/var/www/compta/session`), you need to mount a volume:

```yaml
services:
  php:
    volumes:
      - sessions:/var/www/compte/sessions  # Match your Dockerfile

volumes:
  sessions:
```

**Note:** Docker Compose automatically namespaces volumes as `<instance>_sessions`.

### Port Conflicts

Each instance should use unique ports. Set in `.env`:

```bash
NGINX_HTTP_PORT=38080   # identification
NGINX_HTTP_PORT=38081   # compta
NGINX_HTTP_PORT=38082   # another app
```

---

## Migration Checklist

When migrating an existing project (like identification2023 or compta-2022) to ocompose:

- [ ] Copy `www/` contents to `instances/<name>/www/`
- [ ] Copy `docker/config/` files to `instances/<name>/docker/config/`
- [ ] Copy `docker/nginx/default.conf` to `instances/<name>/docker/nginx/`
- [ ] Copy relevant docker-compose.override.yml example to `instances/<name>/`
- [ ] Update Dockerfile if needed (session paths, permissions)
- [ ] Set `PHP_VERSION` in `instances/<name>/.env` (5.6, 7.4, 8.3, etc.)
- [ ] Set `NGINX_HTTP_PORT` to avoid conflicts
- [ ] Update database.php to use `host.docker.internal:23306`
- [ ] Test: `ocompose <name> up`

---

## Troubleshooting

**Config files not being overridden?**
- Verify paths are correct (relative to ocompose root)
- Check `${PROJECT_NAME}` matches your instance name
- Ensure target paths match your app structure (`/var/www/html/application/config/development/`)

**Session errors?**
- Check Dockerfile creates the session directory
- Verify volume mount matches Dockerfile path
- Ensure permissions are correct (www-data:www-data, 700)

**Database connection failed?**
- Verify db-docker-server is running
- Check network name: `docker network ls | grep dbserver`
- Confirm DB_HOST in config: `host.docker.internal`
- Test connection from workspace: `mysql -h host.docker.internal -P 23306 -u root -p`

**Port already in use?**
- Change `NGINX_HTTP_PORT` in `.env`
- Check what's using the port: `netstat -ano | findstr :<port>`
