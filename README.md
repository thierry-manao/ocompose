# 🐳 ocompose

**Reproducible Docker Mini OS with configurable tools — multi-instance support.**

Spin up isolated development environments with any combination of PHP, Node.js, Python, MySQL, MariaDB, PostgreSQL, Redis, and more — each instance with its own config, ports, and data.

---

## Quick Start

```bash
# Clone the repo
git clone https://github.com/thierry-manao/ocompose.git
cd ocompose

# Make the CLI executable
chmod +x scripts/ocompose.sh

# Optional: install `ocompose` as a terminal command
./scripts/ocompose.sh install-cli

# Create your first instance
ocompose myapp init

# (Optional) Edit the config
nano instances/myapp/.env

# Start it
ocompose myapp up
```

---

## Services

| Service | Profiles | Description |
| --- | --- | --- |
| **Workspace** | ✅ Always | Ubuntu mini-OS with Git, curl, vim, wget, SSH server |
| **Nginx** | ⚙️ All runtimes | Reverse proxy / static file server |
| **PHP** | `APP_RUNTIME=php` | PHP-FPM + Composer (PHP 5.6 – 8.4+ via sury.org) |
| **Node.js** | `APP_RUNTIME=node` | Node.js runtime with nodemon & pm2 |
| **Python** | `APP_RUNTIME=python` | Python runtime with gunicorn & uvicorn |
| **MySQL** | `DB_ENGINE=mysql` | MySQL server |
| **MariaDB** | `DB_ENGINE=mariadb` | MariaDB server (drop-in MySQL replacement) |
| **PostgreSQL** | `DB_ENGINE=postgres` | PostgreSQL server |
| **phpMyAdmin** | `DB_ADMIN_ENABLED=true` | Web UI for MySQL / MariaDB (auto-selected) |
| **pgAdmin** | `DB_ADMIN_ENABLED=true` | Web UI for PostgreSQL (auto-selected) |
| **Redis** | `REDIS_ENABLED=true` | In-memory cache and message broker |

---

## Multi-Instance

Each instance is fully isolated with its own containers, network, volumes, and ports.

```bash
# Create multiple instances
ocompose client-a init    # ports: 8000, 3306, 8080, 2222
ocompose blog init        # ports: 8010, 3316, 8090, 2232

# Start them independently
ocompose client-a up
ocompose blog up

# List all instances
ocompose list
```

Output:

```
📦 ocompose instances:

  INSTANCE             STATUS       RUNTIME    DB         APP                DB PORT    ADMIN      SSH
  client-a             running      php        mysql      8000               3306       8080       2222
  blog                 running      node       postgres   8010               5442       8090       2232
```

---

## CLI Setup

Install the command into your user bin directory:

```bash
./scripts/ocompose.sh install-cli
```

Default install location: `~/.local/bin/ocompose`

Custom install location:

```bash
./scripts/ocompose.sh install-cli ~/bin
```

Remove it later:

```bash
./scripts/ocompose.sh uninstall-cli
```

## CLI Commands

```
Usage: ocompose <instance> <command> [options]
       ocompose list
       ocompose ui [start|stop|restart|status] [port]
       ocompose install-cli [bin-dir]
       ocompose uninstall-cli [bin-dir]

Commands:
  init       Create a new instance
  up         Start the instance
  down       Stop the instance
  restart    Restart the instance
  shell      Open bash in the workspace
  ssh-info   Show SSH connection details
  status     Show container status
  logs       Tail logs
  destroy    Remove instance entirely
  list       List all instances
  ui         Manage the web admin UI
  install-cli     Install the 'ocompose' command
  uninstall-cli   Remove the installed 'ocompose' command
  help       Show this help
```

---

## Web UI

A small admin server for managing instances from the browser. It edits the same `.env` files used by the CLI and can run `init`, `up`, `down`, `restart`, and `destroy`.

Includes a browser console for the workspace container — commands keep state between submissions (`cd`, `git status`, etc.).

Protected by login. Credentials are generated on first start and stored in `.ocompose-ui.auth`.

```bash
ocompose ui                                              # Start on default port 8787
ocompose ui 9090                                         # Custom port
ocompose ui 8787 --username admin --password my-secret   # Custom credentials
ocompose ui status                                       # Check status
ocompose ui restart                                      # Restart
ocompose ui stop                                         # Stop
```

---

## Configuration

Each instance has its own `.env` file at `instances/<name>/.env` and runtime config files under `instances/<name>/config/`.

### Application Runtime

```env
APP_RUNTIME=php        # php | node | python | static | none
```

#### PHP

```env
APP_RUNTIME=php
PHP_VERSION=8.3
PHP_EXTENSIONS="mysql mbstring zip gd curl intl xml"
```

PHP versions are installed from [deb.sury.org](https://packages.sury.org/php/) (PHP 5.6 – 8.4+). Extensions are installed as distro packages.

#### Node.js

```env
APP_RUNTIME=node
NODE_VERSION=20
NODE_COMMAND=node server.js
```

The Node container includes `nodemon` and `pm2` globally. Override `NODE_COMMAND` to use any start command (e.g. `npm start`, `nodemon app.js`).

#### Python

```env
APP_RUNTIME=python
PYTHON_VERSION=3.12
PYTHON_COMMAND=gunicorn app:app --bind 0.0.0.0:8000
```

The Python container includes `gunicorn` and `uvicorn`. Override `PYTHON_COMMAND` for your framework.

#### Static

```env
APP_RUNTIME=static
```

Nginx serves files directly. No backend container.

### Database

```env
DB_ENGINE=mysql        # mysql | mariadb | postgres | external | none
DB_VERSION=8.0         # Image tag (e.g. 8.0, 10.11, 16)
DB_DATABASE=app_db
DB_USER=app
DB_PASSWORD=secret
DB_ROOT_PASSWORD=root
DB_PORT=3306
```

Database admin is auto-selected: phpMyAdmin for MySQL/MariaDB, pgAdmin for PostgreSQL.

```env
DB_ADMIN_ENABLED=true
DB_ADMIN_PORT=8080

# pgAdmin only
PGADMIN_EMAIL=admin@local.dev
PGADMIN_PASSWORD=secret
```

#### Connecting to External Databases

To connect your instance to an external database server (e.g., db-docker-server running on the host), set `DB_ENGINE=external` and configure the connection:

```env
DB_ENGINE=external
DB_HOST=host.docker.internal    # Special DNS name for host machine
DB_PORT=23306                   # Host port where DB is exposed
DB_DATABASE=your_database       # Database name
DB_USER=root                    # Database user
DB_PASSWORD=root                # Database password
```

**Example: Connecting to db-docker-server**

If you have a `db-docker-server` instance running MariaDB on port 23306:

```bash
# In db-docker-server
dbserver licences status    # Check it's running on port 23306

# In ocompose instance
nano instances/myapp/.env
```

Set:

```env
DB_ENGINE=external
DB_HOST=host.docker.internal
DB_PORT=23306
DB_ROOT_PASSWORD=root
DB_DATABASE=licencesdb
DB_USER=root
DB_PASSWORD=root
```

Then start your instance:

```bash
ocompose myapp up
```

Your PHP/Node/Python containers will now connect to the external database. phpMyAdmin will also connect to it for database management.

### Seed Import

Place `.sql` or `.sql.gz` dumps in the shared `db/` folder:

```text
db/compta.sql
db/gescom.sql
db/paie.sql
```

```env
DB_SEED_FILE=compta.sql
DB_RESEED_ON_STARTUP=true
```

- `DB_RESEED_ON_STARTUP=true` — every `up`/`restart` drops and recreates the database, then imports the dump.
- `DB_RESEED_ON_STARTUP=false` — imports once, then skips until `DB_DATABASE`, `DB_SEED_FILE`, or the dump file changes. State is tracked in `instances/<name>/seed-state/`.

### Redis

```env
REDIS_ENABLED=true
REDIS_VERSION=7
REDIS_PORT=6379
```

Available to all runtimes via hostname `redis`.

### Virtual Hosts

`VHOSTS` defines one or more virtual hosts as a comma-separated list of `port:documentRoot` entries.

```env
VHOSTS=8000:public                         # Single app
VHOSTS=8000:public,8001:api               # App + API
VHOSTS=8000:public,8001:api,8002:admin    # Multiple services
VHOSTS=8000:                               # Serve from www/ root
```

Nginx generates the appropriate config per runtime:
- **PHP**: `fastcgi_pass php:9000`
- **Node.js**: `proxy_pass http://node:3000`
- **Python**: `proxy_pass http://python:8000`
- **Static**: direct file serving

Nginx config and port mappings are regenerated automatically on every `up` / `restart`.

### CodeIgniter Auto-Configuration

#### CodeIgniter 4

When a CI4 project is detected (`application/Config/` or `env` template), ocompose auto-configures `.env` with `CI_ENVIRONMENT`, `app.baseURL`, database connection, etc.

#### CodeIgniter 3

When a CI3 project is detected (`application/config/` + `system/core/`), ocompose generates:

- `.ocompose.env.php` — auto-prepend file that defines `BDD_HOST`, `BDD_USER`, `BDD_PWD`, `APP_ROOT` from Docker env vars
- `application/config/docker/` — environment-specific overrides for `config.php`, `database.php`, `constants.php`
- Forces `ENVIRONMENT = 'docker'` so CI3 loads the `config/docker/` directory

```env
CI3_ENABLED=auto           # auto | true | false
CI3_BASE_URL=              # Override base_url (empty = auto from VHOSTS)
CI3_SESSION_SAVE_PATH=     # Override sess_save_path (default: /tmp/ci_sessions)
CI3_APP_ROOT=              # Override APP_ROOT constant
CI3_EXTRA_CONSTANTS=       # Extra CONST=ENV_VAR pairs, comma-separated
```

The CI3 app source code is **never modified** — all overrides are injected via `auto_prepend_file` and CI3's environment config mechanism.

### Workspace Identity

```env
WORKSPACE_USER=developer
WORKSPACE_UID=1000
WORKSPACE_GID=1000
WORKSPACE_SHELL=/bin/bash
```

### Git Bootstrap

```env
GIT_REPO=https://github.com/example/project.git
GIT_BRANCH=main
GIT_HTTP_USERNAME=
GIT_HTTP_PASSWORD=
```

On `ocompose up`, the repository is cloned into `instances/<name>/www/` the first time, then the branch is checked out on each start. For private HTTPS repos, use a personal access token in `GIT_HTTP_PASSWORD`.

### Backward Compatibility

Old `MYSQL_*`, `PHP_ENABLED`, `MYSQL_ENABLED`, `PHPMYADMIN_ENABLED` env vars are automatically mapped to the new `DB_*`, `APP_RUNTIME`, `DB_ENGINE`, `DB_ADMIN_ENABLED` vars. Existing `.env` files keep working without changes.

---

## Per-Instance Config Files

```text
instances/<name>/config/nginx/default.conf      # Auto-generated from VHOSTS + APP_RUNTIME
instances/<name>/config/php/php.ini
instances/<name>/config/mysql/my.cnf
instances/<name>/config/mariadb/my.cnf
instances/<name>/config/ssh/authorized_keys
instances/<name>/config/ssh/id_ed25519
instances/<name>/config/ssh/id_ed25519.pub
instances/<name>/seed-state/
```

Each instance can customize PHP, database, or Nginx settings independently.

---

## Project Structure

```
ocompose/
├── docker-compose.yml
├── .env.example
├── instances/
│   └── <name>/
│       ├── .env
│       ├── docker-compose.vhosts.yml      # Auto-generated
│       ├── config/
│       │   ├── nginx/default.conf
│       │   ├── php/php.ini
│       │   ├── mysql/my.cnf
│       │   ├── mariadb/my.cnf
│       │   └── ssh/
│       ├── seed-state/
│       └── www/
├── db/                                     # Shared SQL dumps
├── services/
│   ├── workspace/Dockerfile                # Base OS + SSH (mandatory)
│   ├── php/Dockerfile                      # PHP-FPM (5.6 – 8.4+)
│   ├── node/Dockerfile                     # Node.js (14 – 22+)
│   └── python/Dockerfile                   # Python (3.8 – 3.12+)
├── config/
│   ├── nginx/default.conf
│   ├── php/php.ini
│   ├── mysql/my.cnf
│   └── mariadb/my.cnf
├── scripts/ocompose.sh
├── web-ui/
│   ├── server.js
│   └── public/
└── www/index.php
```

---

## SSH Access

Each instance runs an SSH server for external developer access.

- `ocompose <instance> init` generates an ed25519 keypair
- Password authentication is disabled — key-based only
- `WORKSPACE_SSH_PORT` controls the host port (auto-assigned on init)

```bash
# Show SSH connection details
ocompose myapp ssh-info

# Give a dev access using their own key
cat their_key.pub >> instances/myapp/config/ssh/authorized_keys

# They connect with:
ssh -p 2222 developer@your-server
```

No container restart needed after adding keys.

---

## License

MIT
