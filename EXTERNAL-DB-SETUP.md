# External Database Connection Guide

This guide explains how to connect ocompose instances to external database servers like db-docker-server.

## Overview

Instead of running a database container within each ocompose instance, you can connect to a centralized database server running separately on the host machine.

## Architecture

```
┌─────────────────────────────────────────┐
│  Host Machine (Windows/WSL)             │
│                                          │
│  ┌────────────────────────────────┐     │
│  │ db-docker-server               │     │
│  │ - MariaDB on port 23306        │     │
│  │ - Databases: licencesdb,       │     │
│  │   gtpdb500001, etc.            │     │
│  └────────────────────────────────┘     │
│              ▲                           │
│              │ host.docker.internal      │
│              │ (host-gateway)            │
│  ┌───────────┴────────────────────┐     │
│  │ ocompose instance (test)       │     │
│  │ - PHP/Node/Python containers   │     │
│  │ - phpMyAdmin                   │     │
│  │ - Connect to external DB       │     │
│  └────────────────────────────────┘     │
│                                          │
└─────────────────────────────────────────┘
```

## Setup Steps

### 1. Start db-docker-server

Ensure your database server is running:

```bash
cd d:/works/db-docker-server
./dbserver licences status

# If not running:
./dbserver licences up
```

Check exposed ports and databases:
- **MariaDB**: `localhost:23306`
- **phpMyAdmin**: `http://localhost:28080`
- **Databases**: `licencesdb`, `gtpdb500001`
- **Credentials**: root/root

### 2. Configure ocompose Instance

Edit your ocompose instance configuration:

```bash
cd d:/works/ocompose
nano instances/test/.env
```

Update database settings:

```env
# Use 'external' to skip creating a local database container
DB_ENGINE=external

# Connection to host machine's database
DB_HOST=host.docker.internal    # Special DNS for host in Docker
DB_PORT=23306                   # db-docker-server's exposed port

# Credentials matching db-docker-server
DB_ROOT_PASSWORD=root
DB_USER=root
DB_PASSWORD=root

# Database to use
DB_DATABASE=licencesdb          # or gtpdb500001, compta, etc.
```

### 3. Start ocompose Instance

```bash
./ocompose test up
```

Your application containers will now connect to the external database server.

## Verification

### Test Database Connection from PHP

Create a test file in `instances/test/www/test-db.php`:

```php
<?php
$host = getenv('DB_HOST') ?: 'localhost';
$port = getenv('DB_PORT') ?: 3306;
$db = getenv('DB_DATABASE');
$user = getenv('DB_USER');
$pass = getenv('DB_PASSWORD');

echo "Connecting to: $host:$port<br>";
echo "Database: $db<br>";
echo "User: $user<br><br>";

try {
    $pdo = new PDO("mysql:host=$host;port=$port;dbname=$db", $user, $pass);
    echo "✓ Connected successfully!<br>";

    $stmt = $pdo->query("SHOW TABLES");
    echo "<br>Tables in $db:<br>";
    while ($row = $stmt->fetch(PDO::FETCH_NUM)) {
        echo "- " . $row[0] . "<br>";
    }
} catch (PDOException $e) {
    echo "✗ Connection failed: " . $e->getMessage();
}
?>
```

Visit `http://localhost:8000/test-db.php` to verify the connection.

### Test from Node.js

Create `instances/test/www/test-db.js`:

```javascript
const mysql = require('mysql2/promise');

async function testConnection() {
    const config = {
        host: process.env.DB_HOST || 'localhost',
        port: process.env.DB_PORT || 3306,
        user: process.env.DB_USER || 'root',
        password: process.env.DB_PASSWORD || 'root',
        database: process.env.DB_DATABASE
    };

    console.log('Connecting to:', config.host + ':' + config.port);
    console.log('Database:', config.database);

    try {
        const connection = await mysql.createConnection(config);
        console.log('✓ Connected successfully!');

        const [rows] = await connection.query('SHOW TABLES');
        console.log('\nTables:');
        rows.forEach(row => console.log('-', Object.values(row)[0]));

        await connection.end();
    } catch (err) {
        console.error('✗ Connection failed:', err.message);
    }
}

testConnection();
```

Run: `node test-db.js`

## Using phpMyAdmin with External Database

phpMyAdmin in ocompose is automatically configured to connect to the external database:

1. Access: `http://localhost:8080`
2. Login with credentials from `.env`:
   - Server: `host.docker.internal:23306`
   - Username: `root`
   - Password: `root`

You can also enable arbitrary server connections by setting `PMA_ARBITRARY=1` (already configured).

## Multiple Databases

If your db-docker-server has multiple databases, you can:

1. **Switch databases** by changing `DB_DATABASE` in `.env` and restarting
2. **Create multiple ocompose instances**, each connecting to a different database:

```bash
# Instance 1: connects to licencesdb
ocompose licences init
# Edit instances/licences/.env → DB_DATABASE=licencesdb
ocompose licences up

# Instance 2: connects to gtpdb500001
ocompose gtp init
# Edit instances/gtp/.env → DB_DATABASE=gtpdb500001
ocompose gtp up
```

## Shared vs. Dedicated Database Servers

### When to Use External Database (db-docker-server)

✅ **Use external when:**
- Multiple applications share the same databases
- You want centralized database management
- Data persistence across multiple app instances
- Consistent database versions and configuration

### When to Use Built-in Database

✅ **Use built-in when:**
- Each instance needs isolated, independent data
- Development/testing with disposable data
- Simple single-app deployments
- You want faster startup (no external dependencies)

## Troubleshooting

### Connection Refused

If you get "Connection refused" errors:

1. Verify db-docker-server is running:
   ```bash
   wsl docker ps | grep dbserver
   ```

2. Check the port is exposed:
   ```bash
   wsl docker port dbserver_licences-mariadb-1
   ```

3. Test from host:
   ```bash
   mysql -h localhost -P 23306 -u root -p
   ```

### host.docker.internal Not Resolving

On Linux/WSL, `host.docker.internal` requires the `extra_hosts` configuration (already added to docker-compose.yml):

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

### Wrong Database Selected

Ensure `DB_DATABASE` matches an existing database in db-docker-server:

```bash
mysql -h localhost -P 23306 -u root -p -e "SHOW DATABASES;"
```

## Environment Variables Reference

### In ocompose `.env`

```env
# External database mode
DB_ENGINE=external              # Required: tells ocompose to use external DB

# Connection settings
DB_HOST=host.docker.internal    # Required: how to reach the DB from containers
DB_PORT=23306                   # Required: host port where DB is exposed
DB_DATABASE=licencesdb          # Required: database name to connect to
DB_USER=root                    # Required: database username
DB_PASSWORD=root                # Required: database password
DB_ROOT_PASSWORD=root           # For phpMyAdmin root access

# These are ignored when DB_ENGINE=external
DB_VERSION=8.0                  # (not used)
DB_SEED_FILE=                   # (not used)
DB_RESEED_ON_STARTUP=false      # (not used)
```

### In Application Code

These environment variables are available in your containers:

- `DB_HOST` → `host.docker.internal`
- `DB_PORT` → `23306`
- `DB_DATABASE` → `licencesdb`
- `DB_USER` → `root`
- `DB_PASSWORD` → `root`

Legacy aliases (for backward compatibility):
- `MYSQL_HOST` → same as `DB_HOST`
- `MYSQL_DATABASE` → same as `DB_DATABASE`
- `MYSQL_USER` → same as `DB_USER`
- `MYSQL_PASSWORD` → same as `DB_PASSWORD`

## Summary

Your ocompose `test` instance is now configured to connect to db-docker-server's MariaDB on port 23306. The configuration:

- ✅ Skips creating a local database container
- ✅ Uses `host.docker.internal:23306` to reach the host's database
- ✅ Shares the same credentials as db-docker-server (root/root)
- ✅ Connects to the `licencesdb` or `gtpdb500001` database
- ✅ phpMyAdmin connects to the same external database

Restart your instance to apply changes:

```bash
./ocompose test restart
```
