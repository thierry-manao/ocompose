
# 🐳 ocompose

**Reproducible Docker Mini OS with configurable tools — multi-instance support.**

Spin up isolated development environments with Nginx, PHP, MySQL, phpMyAdmin, and Git — each with its own config, ports, and data.

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
| **Nginx**      | ⚙️ Configurable | Web server exposing your app on a host port             |
| **PHP**        | ⚙️ Configurable | PHP-FPM + Composer (version configurable)               |
| **MySQL**      | ⚙️ Configurable | MySQL server (version configurable)                     |
| **phpMyAdmin** | ⚙️ Configurable | Web UI for MySQL                                        |

---

## Multi-Instance

Each instance is fully isolated with its own containers, network, volumes, and ports.

```bash
# Create multiple instances
./scripts/ocompose.sh client-a init    # ports: 8000, 3306, 8080, 2222
./scripts/ocompose.sh blog init        # ports: 8010, 3316, 8090, 2232

# Start them independently
./scripts/ocompose.sh client-a up
./scripts/ocompose.sh blog up

# List all instances
./scripts/ocompose.sh list
```

Output:

```
📦 ocompose instances:

  INSTANCE             STATUS       APP        MYSQL      PMA        SSH
  client-a             running      8000       3306       8080       2222
  blog                 running      8010       3316       8090       2232
```

---

## CLI Commands

```
Usage: ocompose.sh <instance> <command> [options]
       ocompose.sh list
  ocompose.sh ui [port]

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
  ui         Start the web admin UI
  help       Show this help
```

## Web UI

The project now includes a small admin server for instance management. It edits the same `instances/<name>/.env` files used by the CLI, and it can also run `init`, `up`, `down`, `restart`, and `destroy` for you.

```bash
./scripts/ocompose.sh ui
```

Then open:

```text
http://localhost:8787
```

Optional custom port:

```bash
./scripts/ocompose.sh ui 9090
```

The UI now starts in the background and writes its PID and logs to the project root. You can inspect or stop it with:

```bash
./scripts/ocompose.sh ui status
./scripts/ocompose.sh ui stop
```

---

## Configuration

Each instance has its own `.env` file at `instances/<name>/.env` and its own runtime config files under `instances/<name>/config/`.

Toggle services on/off:

```env
PHP_ENABLED=true
MYSQL_ENABLED=true
PHPMYADMIN_ENABLED=false   # disable phpMyAdmin
```

App access:

```env
APP_PORT=8000
```

Then open:

```text
http://localhost:8000
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

Per-instance runtime config files are created automatically from the versioned defaults in `config/`:

```text
instances/<name>/config/nginx/default.conf
instances/<name>/config/php/php.ini
instances/<name>/config/mysql/my.cnf
```

That means one instance can change PHP, MySQL, or Nginx settings without affecting the others.

---

## Project Structure

```
ocompose/
├── docker-compose.yml          # Shared compose template
├── .env.example                # Config template
├── instances/                  # Per-instance data & config
│   ├── client-a/
│   │   ├── .env
│   │   ├── config/
│   │   │   ├── nginx/default.conf
│   │   │   ├── php/php.ini
│   │   │   └── mysql/my.cnf
│   │   └── www/
│   └── blog/
│       ├── .env
│       ├── config/
│       └── www/
├── services/
│   ├── workspace/Dockerfile    # Base OS + Git (mandatory)
│   └── php/Dockerfile          # PHP-FPM + Composer
├── config/
│   ├── nginx/default.conf      # Default Nginx template copied into instances
│   ├── php/php.ini             # Default PHP template copied into instances
│   └── mysql/my.cnf            # Default MySQL template copied into instances
├── scripts/
│   └── ocompose.sh             # Multi-instance CLI
└── www/
    └── index.php               # Default landing page template
```

---

## License

MIT
