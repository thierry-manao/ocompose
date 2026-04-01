
# 🐳 ocompose

**Reproducible Docker Mini OS with configurable tools — multi-instance support.**

Spin up isolated development environments with PHP, MySQL, phpMyAdmin, and Git — each with its own config, ports, and data.

---

## Quick Start

```bash
# Clone the repo
git clone https://github.com/thierry-manao/ocompose.git
cd ocompose

# Make the CLI executable
chmod +x scripts/ocompose.sh

# Create your first instance
./scripts/ocompose.sh myapp init

# (Optional) Edit the config
nano instances/myapp/.env

# Start it
./scripts/ocompose.sh myapp up
```

---

## Services

| Service              | Type              | Description                                             |
| -------------------- | ----------------- | ------------------------------------------------------- |
| **Workspace**  | ✅ Mandatory      | Ubuntu mini-OS with**Git**, curl, vim, wget, etc. |
| **PHP**        | ⚙️ Configurable | PHP-FPM + Composer (version configurable)               |
| **MySQL**      | ⚙️ Configurable | MySQL server (version configurable)                     |
| **phpMyAdmin** | ⚙️ Configurable | Web UI for MySQL                                        |

---

## Multi-Instance

Each instance is fully isolated with its own containers, network, volumes, and ports.

```bash
# Create multiple instances
./scripts/ocompose.sh client-a init    # ports: 3306, 8080, 2222
./scripts/ocompose.sh blog init        # ports: 3316, 8090, 2232

# Start them independently
./scripts/ocompose.sh client-a up
./scripts/ocompose.sh blog up

# List all instances
./scripts/ocompose.sh list
```

Output:

```
📦 ocompose instances:

   INSTANCE             STATUS       MYSQL      PMA        SSH
   client-a             running      3306       8080       2222
   blog                 running      3316       8090       2232
```

---

## CLI Commands

```
Usage: ocompose.sh <instance> <command> [options]
       ocompose.sh list

Commands:
  init       Create a new instance
  up         Start the instance
  down       Stop the instance
  restart    Restart the instance
  shell      Open bash in the workspace
  status     Show container status
  logs       Tail logs
  destroy    Remove instance entirely
  list       List all instances
  help       Show this help
```

---

## Configuration

Each instance has its own `.env` file at `instances/<name>/.env`.

Toggle services on/off:

```env
PHP_ENABLED=true
MYSQL_ENABLED=true
PHPMYADMIN_ENABLED=false   # disable phpMyAdmin
```

Change versions:

```env
PHP_VERSION=8.1
MYSQL_VERSION=5.7
```

Custom user inside the workspace:

```env
WORKSPACE_USER=john
WORKSPACE_UID=1001
WORKSPACE_GID=1001
```

---

## Project Structure

```
ocompose/
├── docker-compose.yml          # Shared compose template
├── .env.example                # Config template
├── instances/                  # Per-instance data & config
│   ├── client-a/
│   │   ├── .env
│   │   └── www/
│   └── blog/
│       ├── .env
│       └── www/
├── services/
│   ├── workspace/Dockerfile    # Base OS + Git (mandatory)
│   └── php/Dockerfile          # PHP-FPM + Composer
├── config/
│   ├── php/php.ini
│   └── mysql/my.cnf
├── scripts/
│   └── ocompose.sh             # Multi-instance CLI
└── www/
    └── index.php               # Default landing page template
```

---

## License

MIT
