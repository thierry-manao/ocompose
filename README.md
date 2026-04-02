
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

## CLI Setup

Install the command into your user bin directory:

```bash
./scripts/ocompose.sh install-cli
```

Default install location:

```text
~/.local/bin/ocompose
```

Custom install location:

```bash
./scripts/ocompose.sh install-cli ~/bin
```

Remove it later if needed:

```bash
./scripts/ocompose.sh uninstall-cli
```

If your shell cannot find `ocompose`, add the install directory to `PATH`.

## CLI Commands

```
Usage: ocompose <instance> <command> [options]
  ocompose list
  ocompose ui [start] [port]
  ocompose ui stop
  ocompose ui status
  ocompose install-cli [bin-dir]
  ocompose uninstall-cli [bin-dir]

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
  install-cli     Install the `ocompose` command
  uninstall-cli   Remove the installed `ocompose` command
  help       Show this help
```

## Web UI

The project now includes a small admin server for instance management. It edits the same `instances/<name>/.env` files used by the CLI, and it can also run `init`, `up`, `down`, `restart`, and `destroy` for you.

The admin UI is protected by a login. Credentials are generated on first start and stored in `.ocompose-ui.auth`, or you can provide them explicitly when starting the UI.

```bash
ocompose ui
```

Then open:

```text
http://localhost:8787
```

Optional custom port:

```bash
ocompose ui 9090
ocompose ui 8787 --username admin --password change-me-now
```

The UI now starts in the background and writes its PID and logs to the project root. You can inspect or stop it with:

```bash
ocompose ui status
ocompose ui stop
```

Authentication files:

```text
.ocompose-ui.auth
.ocompose-ui.log
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
