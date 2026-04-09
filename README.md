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

# (Optional) Set a repo and branch for auto-bootstrap
# GIT_REPO=https://github.com/example/project.git
# GIT_BRANCH=main

# Start it
ocompose myapp up
```

---

## Services

| Service              | Type              | Description                                             |
| -------------------- | ----------------- | ------------------------------------------------------- |
| **Workspace**  | ✅ Mandatory      | Ubuntu mini-OS with**Git**, curl, vim, wget, etc. |
| **Nginx**      | ⚙️ Configurable | Web server exposing your app on a host port             |
| **PHP**        | ⚙️ Configurable | PHP-FPM + Composer (PHP 5.6 – 8.4+ via sury.org)       |
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

  INSTANCE             STATUS       APP                MYSQL      PMA        SSH
  client-a             running      8000               3306       8080       2222
  blog                 running      8010               3316       8090       2232
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
  ocompose ui restart [port]
  ocompose ui status
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
  ui         Start the web admin UI
  install-cli     Install the `ocompose` command
  uninstall-cli   Remove the installed `ocompose` command
  help       Show this help
```

## Web UI

The project now includes a small admin server for instance management. It edits the same `instances/<name>/.env` files used by the CLI, and it can also run `init`, `up`, `down`, `restart`, and `destroy` for you.

It also includes a browser console for the workspace container of a running instance. The console keeps a live shell session in the browser, so commands such as `cd`, `pwd`, and `git status` keep state between submissions.

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
ocompose ui restart
ocompose ui stop
```

If you change the web UI backend or client files while it is already running in the background, restart it so the new code is loaded.

Authentication files:

```text
.ocompose-ui.auth
.ocompose-ui.log
```

Web console notes:

```text
- Available only when the instance is running
- Commands run inside <instance>_workspace
- Working directory defaults to /home/<WORKSPACE_USER>/workspace
- The shell session is persistent while the page stays open
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

Reference DB import:

```env
MYSQL_DATABASE=app_db
MYSQL_SEED_FILE=paie.sql
MYSQL_RESEED_ON_STARTUP=true
```

`ocompose <instance> up` ensures `MYSQL_DATABASE` exists, then imports the selected dump into that database.

App access:

```env
VHOSTS=8000:public
```

Then open:

```text
http://localhost:8000
```

### Virtual Hosts

`VHOSTS` defines one or more virtual hosts as a comma-separated list of `port:documentRoot` entries. Each entry creates its own nginx server block and port mapping.

**Single app** (default):

```env
VHOSTS=8000:public
```

**App + API** (same repo, different entry points):

```env
VHOSTS=8000:public,8001:api
```

→ `http://localhost:8000` serves from `www/public/`, `http://localhost:8001` serves from `www/api/`

**Multiple services:**

```env
VHOSTS=8000:public,8001:api,8002:admin,8003:docs
```

**Serve from workspace root** (no subdirectory):

```env
VHOSTS=8000:
```

Nginx config and port mappings are regenerated automatically on every `up` / `restart`.

Legacy `APP_PORT` and `NGINX_DOCUMENT_ROOT` are still supported for backward compatibility — if `VHOSTS` is empty, ocompose falls back to those values.

**CodeIgniter auto-configuration:**

When you restart an instance with a CodeIgniter 4 project, ocompose will automatically configure the `.env` file inside your workspace to:

- Set `CI_ENVIRONMENT = development`
- Set `app.baseURL` to `http://<server-ip>:<first-vhost-port>/` (auto-detected from server)
- Disable `app.forceGlobalSecureRequests` to prevent HTTPS redirects
- Configure database connection using your MySQL settings

The base URL is automatically detected using the server's primary IP address and the first port from your `VHOSTS` config. This means CodeIgniter projects work out of the box without manual `.env` editing.

If you need to override the auto-detected URL (e.g., for a custom domain), you can manually add `APP_BASE_URL` to your instance's `.env` file.

Change versions:

```env
PHP_VERSION=7.4
MYSQL_VERSION=5.7
```

PHP versions are installed from the [deb.sury.org](https://packages.sury.org/php/) repository, which supports PHP 5.6 through 8.4+. Extensions are installed as distro packages (e.g. `mysql`, `mbstring`, `gd`).

Custom user inside the workspace:

```env
WORKSPACE_USER=john
WORKSPACE_UID=1001
WORKSPACE_GID=1001
```

Git bootstrap on startup:

```env
GIT_REPO=https://github.com/example/project.git
GIT_BRANCH=main
GIT_HTTP_USERNAME=
GIT_HTTP_PASSWORD=
```

When these values are set, `ocompose <instance> up` clones the repository into `instances/<name>/www` the first time, then checks out the configured branch on each start. Existing non-empty workspaces are left alone unless they only contain the default placeholder `index.php`.

For private HTTPS repositories, you can optionally set `GIT_HTTP_USERNAME` and `GIT_HTTP_PASSWORD` so the host git clone runs non-interactively. For GitLab, prefer using a personal access token in `GIT_HTTP_PASSWORD` instead of your actual account password.

**Workspace permissions**: After cloning, the workspace is automatically set to `777` permissions to ensure PHP-FPM can write to directories like `writable/` in CodeIgniter or `storage/` in Laravel.

Per-instance runtime config files are created automatically from the versioned defaults in `config/`:

```text
instances/<name>/config/nginx/default.conf
instances/<name>/config/php/php.ini
instances/<name>/config/mysql/my.cnf
instances/<name>/config/ssh/authorized_keys
instances/<name>/config/ssh/id_ed25519
instances/<name>/config/ssh/id_ed25519.pub
instances/<name>/seed-state/
```

That means one instance can change PHP, MySQL, or Nginx settings without affecting the others.

MySQL seed import from the shared `db/` folder:

```text
db/compta.sql
db/gescom.sql
db/paie.sql
```

Set `MYSQL_SEED_FILE` to one of the files in `db/`.

If `MYSQL_RESEED_ON_STARTUP=true`, every `up` and `restart` drops and recreates `MYSQL_DATABASE`, then imports the selected dump.

If `MYSQL_RESEED_ON_STARTUP=false`, ocompose imports the dump the first time, then skips later imports until `MYSQL_DATABASE`, `MYSQL_SEED_FILE`, or the dump content changes. Import state is tracked in `instances/<name>/seed-state/mysql-seed.signature`.

---

## Project Structure

```
ocompose/
├── docker-compose.yml          # Shared compose template
├── .env.example                # Config template
├── instances/                  # Per-instance data & config
│   ├── client-a/
│   │   ├── .env
│   │   ├── docker-compose.vhosts.yml  # Auto-generated port mappings
│   │   ├── config/
│   │   │   ├── nginx/default.conf
│   │   │   ├── php/php.ini
│   │   │   ├── mysql/my.cnf
│   │   │   └── ssh/
│   │   │       ├── authorized_keys
│   │   │       ├── id_ed25519
│   │   │       └── id_ed25519.pub
│   │   ├── seed-state/
│   │   └── www/
│   └── blog/
│       ├── .env
│       ├── config/
│       ├── seed-state/
│       └── www/
├── db/
│   ├── compta.sql
│   ├── gescom.sql
│   └── paie.sql
├── services/
│   ├── workspace/
│   │   ├── Dockerfile          # Base OS + Git + SSH (mandatory)
│   │   └── entrypoint.sh       # Starts sshd then exec CMD
│   └── php/Dockerfile          # PHP-FPM via sury.org (5.6 – 8.4+)
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

## SSH Access

Each instance runs an SSH server so external developers can connect directly to the workspace container.

**How it works:**

- `ocompose <instance> init` generates an ed25519 keypair in `instances/<name>/config/ssh/`
- The public key is automatically added to `authorized_keys`
- The workspace container starts `sshd` on port 22, exposed on the host via `WORKSPACE_SSH_PORT`
- Password authentication is disabled — only key-based access is allowed

**Give a dev access using the generated key:**

```bash
# Show SSH connection details
ocompose myapp ssh-info

# Send the private key to the dev
# They connect with:
ssh -i id_ed25519 -p 2222 developer@your-server
```

**Give a dev access using their own key:**

```bash
# Append their public key to the instance authorized_keys
cat their_key.pub >> instances/myapp/config/ssh/authorized_keys

# They connect with:
ssh -p 2222 developer@your-server
```

No container restart is needed after adding keys — sshd reads `authorized_keys` on each connection.

---

## License

MIT
