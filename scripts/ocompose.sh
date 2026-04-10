#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTANCES_DIR="$PROJECT_DIR/instances"
UI_PID_FILE="$PROJECT_DIR/.ocompose-ui.pid"
UI_LOG_FILE="$PROJECT_DIR/.ocompose-ui.log"
UI_AUTH_FILE="$PROJECT_DIR/.ocompose-ui.auth"
CLI_WRAPPER_FILE="$PROJECT_DIR/ocompose"
CLI_WRAPPER_CMD_FILE="$PROJECT_DIR/ocompose.cmd"

# ── Quiet mode: suppress verbose output when not on a terminal (web UI, CI) ──
if [[ -t 1 ]]; then
    OCOMPOSE_QUIET="false"
else
    OCOMPOSE_QUIET="true"
fi

# Print only in interactive (terminal) mode
log_verbose() {
    [[ "$OCOMPOSE_QUIET" == "true" ]] && return 0
    echo -e "$@"
}

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Validate instance ──
require_instance() {
    if [[ -z "${INSTANCE:-}" ]]; then
        echo -e "${RED}✗ Error: No instance name provided.${NC}"
        echo "  Usage: ocompose.sh <instance> <command>"
        echo "  Example: ocompose.sh client-a up"
        exit 1
    fi
}

normalize_env_file() {
    local env_file="$INSTANCES_DIR/$INSTANCE/.env"
    local normalized_env_file

    normalized_env_file="$(mktemp)"
    sed 's/\r$//' "$env_file" > "$normalized_env_file"
    echo "$normalized_env_file"
}

copy_if_missing() {
    local source_file="$1"
    local target_file="$2"

    if [[ ! -f "$target_file" && -f "$source_file" ]]; then
        # Docker creates directories for bind-mount targets that don't exist as
        # files.  Remove the placeholder directory so the real file can be copied.
        [[ -d "$target_file" ]] && rm -rf "$target_file"
        mkdir -p "$(dirname "$target_file")"
        cp "$source_file" "$target_file"
    fi
}

workspace_is_empty() {
    local workspace_dir="$1"

    [[ -z "$(find "$workspace_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

is_ocompose_placeholder_index() {
    local index_file="$1"

    [[ -f "$index_file" ]] || return 1
    grep -q "getenv('PROJECT_NAME')" "$index_file" || return 1
    grep -q "MySQL Connection" "$index_file" || return 1
    grep -q "phpversion()" "$index_file" || return 1
}

is_http_repo_url() {
    local repo_url="$1"

    [[ "$repo_url" =~ ^https?:// ]]
}

build_git_http_auth_header() {
    local username="${GIT_HTTP_USERNAME:-}"
    local password="${GIT_HTTP_PASSWORD:-}"

    if [[ -z "$username" || -z "$password" ]]; then
        echo -e "${RED}✗ Both GIT_HTTP_USERNAME and GIT_HTTP_PASSWORD must be set for non-interactive HTTPS git auth.${NC}"
        exit 1
    fi

    printf '%s' "$username:$password" | base64 | tr -d '\r\n'
}

escape_mysql_string_literal() {
    local value="${1:-}"

    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"
    printf '%s' "$value"
}

run_git_repo_command() {
    local repo_url="$1"
    shift

    if is_http_repo_url "$repo_url" && [[ -n "${GIT_HTTP_USERNAME:-}" || -n "${GIT_HTTP_PASSWORD:-}" ]]; then
        local auth_header
        auth_header="$(build_git_http_auth_header)"
        git \
            -c credential.helper= \
            -c core.askPass= \
            -c credential.interactive=never \
            -c "http.extraHeader=Authorization: Basic $auth_header" \
            "$@"
        return
    fi

    git "$@"
}

seed_state_dir() {
    echo "$INSTANCES_DIR/$INSTANCE/seed-state"
}

seed_marker_file() {
    echo "$(seed_state_dir)/mysql-seed.signature"
}

compute_file_signature() {
    local file_path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file_path" | awk '{print $1}'
        return
    fi

    wc -c < "$file_path" | tr -d '[:space:]'
}

# ── Backward-compatibility: map legacy vars to new generic names ──
resolve_legacy_vars() {
    # Old PHP_ENABLED / MYSQL_ENABLED / PHPMYADMIN_ENABLED → new generic vars
    if [[ -n "${PHP_ENABLED:-}" && -z "${APP_RUNTIME:-}" ]]; then
        [[ "${PHP_ENABLED}" == "true" ]] && export APP_RUNTIME="php" || export APP_RUNTIME="none"
    fi
    if [[ -n "${MYSQL_ENABLED:-}" && -z "${DB_ENGINE:-}" ]]; then
        [[ "${MYSQL_ENABLED}" == "true" ]] && export DB_ENGINE="mysql" || export DB_ENGINE="none"
    fi
    if [[ -n "${PHPMYADMIN_ENABLED:-}" && -z "${DB_ADMIN_ENABLED:-}" ]]; then
        export DB_ADMIN_ENABLED="${PHPMYADMIN_ENABLED}"
    fi

    # Map old MYSQL_* vars to DB_* if the new ones are missing
    [[ -n "${MYSQL_VERSION:-}" && -z "${DB_VERSION:-}" ]]        && export DB_VERSION="${MYSQL_VERSION}"
    [[ -n "${MYSQL_ROOT_PASSWORD:-}" && -z "${DB_ROOT_PASSWORD:-}" ]] && export DB_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}"
    [[ -n "${MYSQL_DATABASE:-}" && -z "${DB_DATABASE:-}" ]]      && export DB_DATABASE="${MYSQL_DATABASE}"
    [[ -n "${MYSQL_USER:-}" && -z "${DB_USER:-}" ]]              && export DB_USER="${MYSQL_USER}"
    [[ -n "${MYSQL_PASSWORD:-}" && -z "${DB_PASSWORD:-}" ]]      && export DB_PASSWORD="${MYSQL_PASSWORD}"
    [[ -n "${MYSQL_PORT:-}" && -z "${DB_PORT:-}" ]]              && export DB_PORT="${MYSQL_PORT}"
    [[ -n "${MYSQL_SEED_FILE:-}" && -z "${DB_SEED_FILE:-}" ]]    && export DB_SEED_FILE="${MYSQL_SEED_FILE}"
    [[ -n "${MYSQL_RESEED_ON_STARTUP:-}" && -z "${DB_RESEED_ON_STARTUP:-}" ]] && export DB_RESEED_ON_STARTUP="${MYSQL_RESEED_ON_STARTUP}"
    [[ -n "${PHPMYADMIN_PORT:-}" && -z "${DB_ADMIN_PORT:-}" ]]   && export DB_ADMIN_PORT="${PHPMYADMIN_PORT}"

    # Ensure backward-compat aliases exist so CI3 prepend and docker-compose work
    export MYSQL_HOST="${DB_ENGINE:-mysql}"
    export MYSQL_DATABASE="${DB_DATABASE:-app_db}"
    export MYSQL_USER="${DB_USER:-app}"
    export MYSQL_PASSWORD="${DB_PASSWORD:-}"
    export MYSQL_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-root}"
}

# ── Validate DB version is pullable by modern Docker/containerd ──
validate_db_version() {
    local engine="${DB_ENGINE:-mysql}"
    local version="${DB_VERSION:-}"
    [[ "$engine" == "none" || -z "$version" ]] && return 0

    # Extract the major.minor as a comparable number (e.g. 10.1 → 1001, 8.0 → 800)
    local major minor
    major="${version%%.*}"
    minor="${version#*.}"; minor="${minor%%.*}"
    [[ "$minor" =~ ^[0-9]+$ ]] || minor=0
    local ver_num=$(( major * 100 + minor ))

    local min_label=""
    case "$engine" in
        mariadb)
            # MariaDB images before 10.2 use the old v1 manifest
            if (( ver_num < 1002 )); then
                min_label="10.2"
            fi
            ;;
        mysql)
            # MySQL images before 5.6 are unavailable
            if (( ver_num < 506 )); then
                min_label="5.6"
            fi
            ;;
    esac

    if [[ -n "$min_label" ]]; then
        echo -e "${YELLOW}⚠  ${engine}:${version} is too old — its Docker image uses a manifest format"
        echo -e "   no longer supported by modern containerd (v2.1+).${NC}"
        echo -e "   → Auto-correcting to ${BOLD}${engine}:${min_label}${NC}"
        export DB_VERSION="$min_label"
    fi
}

resolve_db_seed_file() {
    local seed_file="${DB_SEED_FILE:-}"
    local base_name

    [[ -n "$seed_file" ]] || return 0

    base_name="$(basename "$seed_file")"
    if [[ "$base_name" != "$seed_file" ]]; then
        echo -e "${RED}✗ DB_SEED_FILE must be a filename from the db directory for '$INSTANCE'.${NC}"
        echo "  Value: $seed_file"
        exit 1
    fi

    echo "$PROJECT_DIR/db/$seed_file"
}

# ── Resolve the container name for the active DB engine ──
db_container_name() {
    echo "${INSTANCE}_${DB_ENGINE:-mysql}"
}

wait_for_db_ready() {
    local max_attempts=30
    local attempt=1
    local container
    container="$(db_container_name)"
    local engine="${DB_ENGINE:-mysql}"

    while [[ $attempt -le $max_attempts ]]; do
        # Bail early if the container has already exited (crashed)
        local state
        state="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "missing")"
        if [[ "$state" == "false" || "$state" == "missing" ]]; then
            echo -e "${RED}✗ Database container '${container}' is not running (crashed or failed to start).${NC}"
            echo -e "  Check logs with:  docker logs $container"
            echo -e "  If upgrading DB versions, the old data volume may be incompatible."
            echo -e "  To reset:  docker volume rm ${INSTANCE}_${engine}_data  then retry."
            exit 1
        fi

        case "$engine" in
            mysql|mariadb)
                if docker exec -e MYSQL_PWD="${DB_ROOT_PASSWORD:-root}" "$container" mysqladmin ping -h 127.0.0.1 -uroot --silent >/dev/null 2>&1; then
                    return 0
                fi
                ;;
            postgres)
                if docker exec -e PGPASSWORD="${DB_ROOT_PASSWORD:-root}" "$container" pg_isready -U "${DB_USER:-app}" -q >/dev/null 2>&1; then
                    return 0
                fi
                ;;
        esac

        attempt=$((attempt + 1))
        sleep 2
    done

    echo -e "${RED}✗ Database ($engine) did not become ready in time for '$INSTANCE'.${NC}"
    echo -e "  Check logs with:  docker logs $(db_container_name)"
    return 1
}

ensure_db_exists() {
    local db_name="${DB_DATABASE:-app_db}"
    local container
    container="$(db_container_name)"

    if [[ ! "$db_name" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo -e "${RED}✗ DB_DATABASE contains unsupported characters for '$INSTANCE'.${NC}"
        echo "  Value: $db_name"
        exit 1
    fi

    case "${DB_ENGINE:-mysql}" in
        mysql|mariadb)
            local sql
            printf -v sql 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' "$db_name"
            docker exec -i -e MYSQL_PWD="${DB_ROOT_PASSWORD:-root}" "$container" mysql -uroot -e "$sql"
            ;;
        postgres)
            docker exec -i -e PGPASSWORD="${DB_ROOT_PASSWORD:-root}" "$container" \
                psql -U "${DB_USER:-app}" -tc "SELECT 1 FROM pg_database WHERE datname = '$db_name'" | grep -q 1 \
                || docker exec -i -e PGPASSWORD="${DB_ROOT_PASSWORD:-root}" "$container" \
                    psql -U "${DB_USER:-app}" -c "CREATE DATABASE \"$db_name\";"
            ;;
    esac
}

grant_db_user_access() {
    local db_name="${DB_DATABASE:-app_db}"
    local db_user="${DB_USER:-app}"
    local container
    container="$(db_container_name)"

    # Root user already has all privileges — skip
    [[ "$db_user" == "root" ]] && return 0

    if [[ ! "$db_name" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo -e "${RED}✗ DB_DATABASE contains unsupported characters for '$INSTANCE'.${NC}"
        exit 1
    fi
    if [[ ! "$db_user" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo -e "${RED}✗ DB_USER contains unsupported characters for '$INSTANCE'.${NC}"
        exit 1
    fi

    case "${DB_ENGINE:-mysql}" in
        mysql|mariadb)
            local escaped_password grant_sql
            escaped_password="$(escape_mysql_string_literal "${DB_PASSWORD:-}")"
            grant_sql="CREATE USER IF NOT EXISTS '${db_user}'@'%' IDENTIFIED BY '${escaped_password}'; ALTER USER '${db_user}'@'%' IDENTIFIED BY '${escaped_password}'; GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'%'; FLUSH PRIVILEGES;"
            docker exec -i -e MYSQL_PWD="${DB_ROOT_PASSWORD:-root}" "$container" mysql -uroot -e "$grant_sql"
            ;;
        postgres)
            # postgres user is created by the image via POSTGRES_USER
            ;;
    esac
}

recreate_db() {
    local db_name="${DB_DATABASE:-app_db}"
    local container
    container="$(db_container_name)"

    if [[ ! "$db_name" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo -e "${RED}✗ DB_DATABASE contains unsupported characters for '$INSTANCE'.${NC}"
        exit 1
    fi

    case "${DB_ENGINE:-mysql}" in
        mysql|mariadb)
            local sql
            printf -v sql 'DROP DATABASE IF EXISTS `%s`; CREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' "$db_name" "$db_name"
            docker exec -i -e MYSQL_PWD="${DB_ROOT_PASSWORD:-root}" "$container" mysql -uroot -e "$sql"
            ;;
        postgres)
            docker exec -i -e PGPASSWORD="${DB_ROOT_PASSWORD:-root}" "$container" \
                psql -U "${DB_USER:-app}" -c "DROP DATABASE IF EXISTS \"$db_name\"; CREATE DATABASE \"$db_name\";"
            ;;
    esac
}

db_has_tables() {
    local db_name="${DB_DATABASE:-app_db}"
    local container
    container="$(db_container_name)"
    local table_count

    case "${DB_ENGINE:-mysql}" in
        mysql|mariadb)
            local sql
            printf -v sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '%s';" "$db_name"
            table_count="$(docker exec -i -e MYSQL_PWD="${DB_ROOT_PASSWORD:-root}" "$container" mysql -uroot -N -s -e "$sql" 2>/dev/null | tr -d '[:space:]')"
            ;;
        postgres)
            table_count="$(docker exec -i -e PGPASSWORD="${DB_ROOT_PASSWORD:-root}" "$container" \
                psql -U "${DB_USER:-app}" -d "$db_name" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d '[:space:]')"
            ;;
    esac

    [[ -n "$table_count" && "$table_count" != "0" ]]
}

import_db_seed_if_configured() {
    local seed_path marker_file current_signature previous_signature
    local reseed_on_startup="${DB_RESEED_ON_STARTUP:-true}"
    local engine="${DB_ENGINE:-mysql}"
    local container
    container="$(db_container_name)"

    [[ "$engine" != "none" ]] || return 0
    seed_path="$(resolve_db_seed_file)"
    [[ -n "$seed_path" ]] || return 0

    if [[ ! -f "$seed_path" ]]; then
        echo -e "${RED}✗ DB_SEED_FILE does not exist in '$PROJECT_DIR/db' for '$INSTANCE'.${NC}"
        echo "  Expected file: $seed_path"
        exit 1
    fi

    wait_for_db_ready || {
        echo -e "${RED}✗ Cannot import seed: database not ready.${NC}"
        exit 1
    }

    marker_file="$(seed_marker_file)"
    mkdir -p "$(seed_state_dir)"
    current_signature="${DB_DATABASE}:${DB_SEED_FILE}:$(compute_file_signature "$seed_path")"
    previous_signature="$(cat "$marker_file" 2>/dev/null || true)"

    if [[ "$reseed_on_startup" != "true" ]]; then
        ensure_db_exists
        grant_db_user_access
        if [[ "$current_signature" == "$previous_signature" ]] && db_has_tables; then
            return 0
        fi
    fi

    recreate_db
    grant_db_user_access

    echo -e "${CYAN}🗄 Re-seeding '${BOLD}${DB_DATABASE}${NC}${CYAN}' from '${BOLD}${DB_SEED_FILE}${NC}${CYAN}' for '${BOLD}$INSTANCE${NC}${CYAN}'...${NC}"
    case "$engine" in
        mysql|mariadb)
            case "$seed_path" in
                *.sql)
                    docker exec -i -e MYSQL_PWD="${DB_ROOT_PASSWORD:-root}" "$container" mysql -uroot "${DB_DATABASE}" < "$seed_path"
                    ;;
                *.sql.gz)
                    gzip -cd "$seed_path" | docker exec -i -e MYSQL_PWD="${DB_ROOT_PASSWORD:-root}" "$container" mysql -uroot "${DB_DATABASE}"
                    ;;
                *)
                    echo -e "${RED}✗ Unsupported seed file format for '$INSTANCE'.${NC}"
                    echo "  Supported: .sql, .sql.gz"
                    exit 1
                    ;;
            esac
            ;;
        postgres)
            case "$seed_path" in
                *.sql)
                    docker exec -i -e PGPASSWORD="${DB_ROOT_PASSWORD:-root}" "$container" \
                        psql -U "${DB_USER:-app}" -d "${DB_DATABASE}" < "$seed_path"
                    ;;
                *.sql.gz)
                    gzip -cd "$seed_path" | docker exec -i -e PGPASSWORD="${DB_ROOT_PASSWORD:-root}" "$container" \
                        psql -U "${DB_USER:-app}" -d "${DB_DATABASE}"
                    ;;
                *)
                    echo -e "${RED}✗ Unsupported seed file format for '$INSTANCE'.${NC}"
                    echo "  Supported: .sql, .sql.gz"
                    exit 1
                    ;;
            esac
            ;;
    esac

    printf '%s' "$current_signature" > "$marker_file"
}

workspace_has_only_default_index() {
    local workspace_dir="$1"
    local index_file="$workspace_dir/index.php"
    local entry_count

    [[ -f "$index_file" ]] || return 1
    is_ocompose_placeholder_index "$index_file" || return 1

    entry_count="$(find "$workspace_dir" -mindepth 1 -maxdepth 1 ! -name '.git' | wc -l | tr -d '[:space:]')"
    [[ "$entry_count" == "1" ]]
}

prepare_workspace_for_clone() {
    local workspace_dir="$1"

    if workspace_is_empty "$workspace_dir"; then
        return 0
    fi

    if workspace_has_only_default_index "$workspace_dir"; then
        rm -f "$workspace_dir/index.php"
        return 0
    fi

    # Non-interactive (web UI, CI) or no .git dir (failed previous clone):
    # auto-clean since GIT_REPO is explicitly configured.
    if [[ ! -t 0 ]] || [[ ! -d "$workspace_dir/.git" ]]; then
        echo -e "${YELLOW}⚠  Auto-cleaning '$workspace_dir' (leftover files, no valid repo).${NC}"
        docker run --rm -v "$workspace_dir:/target" alpine sh -c 'rm -rf /target/* /target/.[!.]* /target/..?*' 2>/dev/null || true
        rm -rf "$workspace_dir"/* "$workspace_dir"/.[!.]* 2>/dev/null || true
        return 0
    fi

    echo -e "${YELLOW}⚠  '$workspace_dir' already contains files (leftover from a previous run).${NC}"
    read -p "   Remove existing contents and clone fresh? (y/N): " clean_confirm
    if [[ "$clean_confirm" == "y" || "$clean_confirm" == "Y" ]]; then
        docker run --rm -v "$workspace_dir:/target" alpine sh -c 'rm -rf /target/* /target/.[!.]* /target/..?*' 2>/dev/null || true
        rm -rf "$workspace_dir"/* "$workspace_dir"/.[!.]* 2>/dev/null || true
        return 0
    fi

    echo -e "${RED}✗ Cannot clone into '$workspace_dir' because it already contains files.${NC}"
    echo "  Remove the existing contents or destroy the instance first:  ocompose $INSTANCE destroy"
    exit 1
}

checkout_instance_branch() {
    local workspace_dir="$1"
    local branch="$2"
    local repo_url="$3"
    local _quiet_flag=""
    [[ "$OCOMPOSE_QUIET" == "true" ]] && _quiet_flag="--quiet"

    [[ -z "$branch" ]] && return 0

    if git -C "$workspace_dir" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$workspace_dir" checkout $_quiet_flag "$branch"
        return 0
    fi

    if git -C "$workspace_dir" remote get-url origin >/dev/null 2>&1; then
        run_git_repo_command "$repo_url" -C "$workspace_dir" fetch $_quiet_flag origin "$branch" --prune
        git -C "$workspace_dir" checkout $_quiet_flag -B "$branch" --track "origin/$branch"
        return 0
    fi

    echo -e "${RED}✗ Branch '$branch' was requested, but no origin remote is configured.${NC}"
    exit 1
}

bootstrap_instance_git_repo() {
    local workspace_dir="$INSTANCES_DIR/$INSTANCE/www"
    local repo_url="${GIT_REPO:-}"
    local branch="${GIT_BRANCH:-}"
    local current_origin=""

    if [[ -z "$repo_url" && -z "$branch" ]]; then
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo -e "${RED}✗ Git is required on the host when GIT_REPO or GIT_BRANCH is configured.${NC}"
        exit 1
    fi

    mkdir -p "$workspace_dir"

    if [[ -d "$workspace_dir/.git" ]]; then
        if git -C "$workspace_dir" remote get-url origin >/dev/null 2>&1; then
            current_origin="$(git -C "$workspace_dir" remote get-url origin)"
        fi

        if [[ -n "$repo_url" && -n "$current_origin" && "$current_origin" != "$repo_url" ]]; then
            log_verbose "${YELLOW}⚠ Repository URL changed for '$INSTANCE'. Removing old workspace...${NC}"
            log_verbose "  Old origin: $current_origin"
            log_verbose "  New origin: $repo_url"
            rm -rf "$workspace_dir"
            mkdir -p "$workspace_dir"

            log_verbose "${CYAN}📥 Cloning new repository for '${BOLD}$INSTANCE${NC}${CYAN}'...${NC}"
            if [[ -n "$branch" ]]; then
                run_git_repo_command "$repo_url" clone --quiet --branch "$branch" --single-branch "$repo_url" "$workspace_dir"
            else
                run_git_repo_command "$repo_url" clone --quiet "$repo_url" "$workspace_dir"
            fi

            log_verbose "${CYAN}🔒 Setting workspace permissions (777)...${NC}"
            chmod -R 777 "$workspace_dir" 2>/dev/null || true
            return 0
        fi

        if [[ -n "$repo_url" && -z "$current_origin" ]]; then
            git -C "$workspace_dir" remote add origin "$repo_url"
        fi
    else
        if [[ -z "$repo_url" ]]; then
            echo -e "${RED}✗ GIT_BRANCH is set for '$INSTANCE', but there is no cloned repo and GIT_REPO is empty.${NC}"
            exit 1
        fi

        prepare_workspace_for_clone "$workspace_dir"

        log_verbose "${CYAN}📥 Cloning repository for '${BOLD}$INSTANCE${NC}${CYAN}'...${NC}"
        if [[ -n "$branch" ]]; then
            run_git_repo_command "$repo_url" clone --quiet --branch "$branch" --single-branch "$repo_url" "$workspace_dir"
        else
            run_git_repo_command "$repo_url" clone --quiet "$repo_url" "$workspace_dir"
        fi

        log_verbose "${CYAN}🔒 Setting workspace permissions (777)...${NC}"
        chmod -R 777 "$workspace_dir" 2>/dev/null || true
    fi

    if [[ -n "$branch" ]]; then
        log_verbose "${CYAN}🌿 Switching '${BOLD}$INSTANCE${NC}${CYAN}' to branch '${BOLD}$branch${NC}${CYAN}'...${NC}"
        checkout_instance_branch "$workspace_dir" "$branch" "$repo_url"
    fi

    # Set proper permissions for workspace files
    log_verbose "${CYAN}🔒 Setting workspace permissions (777)...${NC}"
    chmod -R 777 "$workspace_dir" 2>/dev/null || true
}

has_flag() {
    local expected_flag="$1"
    shift

    for arg in "$@"; do
        if [[ "$arg" == "$expected_flag" ]]; then
            return 0
        fi
    done

    return 1
}

is_ui_running() {
    if [[ ! -f "$UI_PID_FILE" ]]; then
        return 1
    fi

    local pid
    pid="$(tr -d '[:space:]' < "$UI_PID_FILE")"
    [[ -z "$pid" ]] && return 1

    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    rm -f "$UI_PID_FILE"
    return 1
}

default_cli_bin_dir() {
    if [[ -n "${OCOMPOSE_BIN_DIR:-}" ]]; then
        echo "$OCOMPOSE_BIN_DIR"
        return
    fi

    echo "$HOME/.local/bin"
}

resolve_cli_bin_dir() {
    local provided_dir="${1:-}"

    if [[ -n "$provided_dir" ]]; then
        echo "$provided_dir"
        return
    fi

    default_cli_bin_dir
}

install_wrapper_file() {
    local source_file="$1"
    local target_file="$2"

    rm -f "$target_file"
    if ln -s "$source_file" "$target_file" 2>/dev/null; then
        return 0
    fi

    cp "$source_file" "$target_file"
}

create_cli_launcher() {
    local target_file="$1"

    cat > "$target_file" <<EOF
#!/usr/bin/env bash
set -euo pipefail

exec "$PROJECT_DIR/scripts/ocompose.sh" "\$@"
EOF
}

create_cli_cmd_launcher() {
    local target_file="$1"
    local project_dir_windows
    project_dir_windows="$(cygpath -w "$PROJECT_DIR")"

    cat > "$target_file" <<EOF
@echo off
setlocal
bash "$project_dir_windows\\scripts\\ocompose.sh" %*
EOF
}

path_contains_dir() {
    local dir_to_match="$1"
    local normalized_target
    normalized_target="$(cd "$dir_to_match" 2>/dev/null && pwd || echo "$dir_to_match")"

    IFS=':' read -r -a path_parts <<< "${PATH:-}"
    for path_entry in "${path_parts[@]}"; do
        [[ -z "$path_entry" ]] && continue
        local normalized_entry
        normalized_entry="$(cd "$path_entry" 2>/dev/null && pwd || echo "$path_entry")"
        if [[ "$normalized_entry" == "$normalized_target" ]]; then
            return 0
        fi
    done

    return 1
}

generate_ui_password() {
    local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    local password=''
    local alphabet_length=${#alphabet}

    while [[ ${#password} -lt 24 ]]; do
        local random_byte
        random_byte="$(od -An -N1 -tu1 /dev/urandom | tr -d '[:space:]')"
        password+="${alphabet:$(( random_byte % alphabet_length )):1}"
    done

    printf '%s' "$password"
}

write_ui_auth_file() {
    local username="$1"
    local password="$2"

    cat > "$UI_AUTH_FILE" <<EOF
OCOMPOSE_UI_USERNAME=$username
OCOMPOSE_UI_PASSWORD=$password
EOF
}

ensure_ui_auth_file() {
    if [[ -f "$UI_AUTH_FILE" ]]; then
        return 0
    fi

    local username="${OCOMPOSE_UI_USERNAME:-admin}"
    local password="${OCOMPOSE_UI_PASSWORD:-}"

    if [[ -z "$password" ]]; then
        password="$(generate_ui_password)"
    fi

    write_ui_auth_file "$username" "$password"
}

load_ui_auth() {
    local requested_username="${OCOMPOSE_UI_USERNAME:-}"
    local requested_password="${OCOMPOSE_UI_PASSWORD:-}"

    ensure_ui_auth_file

    set -a
    # shellcheck disable=SC1090
    source "$UI_AUTH_FILE"
    set +a

    if [[ -n "$requested_username" ]]; then
        OCOMPOSE_UI_USERNAME="$requested_username"
    fi

    if [[ -n "$requested_password" ]]; then
        OCOMPOSE_UI_PASSWORD="$requested_password"
    fi
}

cmd_install_cli() {
    local bin_dir
    bin_dir="$(resolve_cli_bin_dir "${1:-}")"
    local target_file="$bin_dir/ocompose"

    mkdir -p "$bin_dir"
    chmod +x "$CLI_WRAPPER_FILE" "$PROJECT_DIR/scripts/ocompose.sh"
    create_cli_launcher "$target_file"
    chmod +x "$target_file"

    if command -v cygpath >/dev/null 2>&1; then
        create_cli_cmd_launcher "$bin_dir/ocompose.cmd"
    elif [[ -f "$CLI_WRAPPER_CMD_FILE" ]]; then
        install_wrapper_file "$CLI_WRAPPER_CMD_FILE" "$bin_dir/ocompose.cmd"
    fi

    echo -e "${GREEN}✅ ocompose CLI installed.${NC}"
    echo -e "   Command: ocompose"
    echo -e "   Location: $target_file"

    if path_contains_dir "$bin_dir"; then
        echo -e "   PATH: already includes $bin_dir"
    else
        echo -e "${YELLOW}⚠  Add this directory to PATH to use 'ocompose' everywhere:${NC}"
        echo -e "   $bin_dir"
    fi
}

cmd_uninstall_cli() {
    local bin_dir
    bin_dir="$(resolve_cli_bin_dir "${1:-}")"
    local removed_any="false"

    if [[ -f "$bin_dir/ocompose" || -L "$bin_dir/ocompose" ]]; then
        rm -f "$bin_dir/ocompose"
        removed_any="true"
    fi

    if [[ -f "$bin_dir/ocompose.cmd" || -L "$bin_dir/ocompose.cmd" ]]; then
        rm -f "$bin_dir/ocompose.cmd"
        removed_any="true"
    fi

    if [[ "$removed_any" == "true" ]]; then
        echo -e "${GREEN}✅ ocompose CLI removed from $bin_dir.${NC}"
    else
        echo -e "${YELLOW}⚠  No installed ocompose CLI was found in $bin_dir.${NC}"
    fi
}

configure_codeigniter_env() {
    local instance_dir="$INSTANCES_DIR/$INSTANCE"
    local ci_env_file="$instance_dir/www/.env"
    local ci_env_template="$instance_dir/www/env"

    # Only configure if CodeIgniter env template exists
    [[ ! -f "$ci_env_template" ]] && return 0

    # Copy template if .env doesn't exist
    if [[ ! -f "$ci_env_file" ]]; then
        cp "$ci_env_template" "$ci_env_file"
    fi

    # Build base URL
    local base_url="${APP_BASE_URL:-}"
    if [[ -z "$base_url" ]]; then
        # Auto-detect server IP or hostname
        local server_host="localhost"

        # Try to get primary IP address
        if command -v hostname >/dev/null 2>&1; then
            local detected_ip
            detected_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
            [[ -n "$detected_ip" ]] && server_host="$detected_ip"
        fi

        # Use the first vhost port
        local first_port="8000"
        if [[ -n "${VHOSTS:-}" ]]; then
            local first_vh="${VHOSTS%%,*}"
            first_port="${first_vh%%:*}"
        elif [[ -n "${APP_PORT:-}" ]]; then
            first_port="${APP_PORT}"
        fi

        base_url="http://${server_host}:${first_port}/"
    fi
    [[ "$base_url" != */ ]] && base_url="${base_url}/"

    # Configure CodeIgniter .env
    log_verbose "${CYAN}⚙️  Configuring CodeIgniter environment...${NC}"

    # Set CI_ENVIRONMENT
    if grep -q "^#.*CI_ENVIRONMENT" "$ci_env_file"; then
        sed -i "s|^#.*CI_ENVIRONMENT.*|CI_ENVIRONMENT = development|" "$ci_env_file"
    elif ! grep -q "^CI_ENVIRONMENT" "$ci_env_file"; then
        echo "CI_ENVIRONMENT = development" >> "$ci_env_file"
    fi

    # Set app.baseURL
    if grep -q "^#.*app\.baseURL" "$ci_env_file"; then
        sed -i "s|^#.*app\.baseURL.*|app.baseURL = '${base_url}'|" "$ci_env_file"
    elif grep -q "^app\.baseURL" "$ci_env_file"; then
        sed -i "s|^app\.baseURL.*|app.baseURL = '${base_url}'|" "$ci_env_file"
    else
        echo "app.baseURL = '${base_url}'" >> "$ci_env_file"
    fi

    # Disable force HTTPS
    if grep -q "^#.*app\.forceGlobalSecureRequests" "$ci_env_file"; then
        sed -i "s|^#.*app\.forceGlobalSecureRequests.*|app.forceGlobalSecureRequests = false|" "$ci_env_file"
    elif grep -q "^app\.forceGlobalSecureRequests" "$ci_env_file"; then
        sed -i "s|^app\.forceGlobalSecureRequests.*|app.forceGlobalSecureRequests = false|" "$ci_env_file"
    else
        echo "app.forceGlobalSecureRequests = false" >> "$ci_env_file"
    fi

    # Set database config if MySQL is enabled
    if [[ "${MYSQL_ENABLED:-false}" == "true" ]]; then
        if ! grep -q "^database\.default\.hostname" "$ci_env_file"; then
            echo "" >> "$ci_env_file"
            echo "database.default.hostname = mysql" >> "$ci_env_file"
            echo "database.default.database = ${MYSQL_DATABASE:-app_db}" >> "$ci_env_file"
            echo "database.default.username = ${MYSQL_USER:-app}" >> "$ci_env_file"
            echo "database.default.password = ${MYSQL_PASSWORD:-secret}" >> "$ci_env_file"
            echo "database.default.DBDriver = MySQLi" >> "$ci_env_file"
        fi
    fi
}

# ── CodeIgniter 3 auto-configuration ──
# Detects CI3 by looking for application/config/ and generates a PHP
# auto_prepend_file that overrides database, session, and path constants
# from Docker environment variables.  Works across different CI3 apps
# without modifying their source code.
configure_ci3_env() {
    local instance_dir="$INSTANCES_DIR/$INSTANCE"
    local www_dir="$instance_dir/www"
    local ci3_enabled="${CI3_ENABLED:-auto}"

    # Explicit disable
    [[ "$ci3_enabled" == "false" ]] && return 0

    # Auto-detect: look for CI3 fingerprint
    if [[ "$ci3_enabled" == "auto" ]]; then
        local detected="false"
        # Check common CI3 structures (direct or inside a subdirectory)
        for candidate in "$www_dir" "$www_dir"/*/; do
            if [[ -d "$candidate/application/config" && -d "$candidate/system/core" ]]; then
                detected="true"
                break
            fi
        done
        [[ "$detected" == "false" ]] && return 0
    fi

    log_verbose "${CYAN}⚙️  Configuring CodeIgniter 3 environment...${NC}"

    # Resolve base URL
    local base_url="${CI3_BASE_URL:-${APP_BASE_URL:-}}"
    if [[ -z "$base_url" ]]; then
        local first_port="8000"
        if [[ -n "${VHOSTS:-}" ]]; then
            local first_vh="${VHOSTS%%,*}"
            first_port="${first_vh%%:*}"
        fi
        base_url="http://localhost:${first_port}/"
    fi
    [[ "$base_url" != */ ]] && base_url="${base_url}/"

    local session_path="${CI3_SESSION_SAVE_PATH:-/tmp/ci_sessions}"
    local app_root="${CI3_APP_ROOT:-/var/www/html}"

    # Build extra constant overrides from CI3_EXTRA_CONSTANTS
    local extra_constants_php=""
    if [[ -n "${CI3_EXTRA_CONSTANTS:-}" ]]; then
        IFS=',' read -ra pairs <<< "$CI3_EXTRA_CONSTANTS"
        for pair in "${pairs[@]}"; do
            pair="$(echo "$pair" | xargs)"
            [[ -z "$pair" || "$pair" != *=* ]] && continue
            local const_name="${pair%%=*}"
            local env_name="${pair#*=}"
            extra_constants_php+="    '${const_name}' => getenv('${env_name}'),"$'\n'
        done
    fi

    # Find all CI3 app roots (direct www or subdirectory)
    local ci3_roots=()
    if [[ -d "$www_dir/application/config" ]]; then
        ci3_roots+=("$www_dir")
    fi
    for candidate in "$www_dir"/*/; do
        [[ -d "$candidate/application/config" && -d "$candidate/system/core" ]] && ci3_roots+=("$candidate")
    done

    for ci3_root in "${ci3_roots[@]}"; do
        local prepend_file="$ci3_root/.ocompose.env.php"
        local relative_root="${ci3_root#"$www_dir"}"
        relative_root="${relative_root%/}"
        local docker_root="/var/www/html${relative_root}"
        local effective_app_root="${CI3_APP_ROOT:-$docker_root}"

        cat > "$prepend_file" <<'PREPEND_HEADER'
<?php
/**
 * Auto-generated by ocompose — do not edit manually.
 * Regenerated on every 'ocompose up'.
 *
 * Loaded via auto_prepend_file to inject Docker environment
 * configuration into CodeIgniter 3 applications.
 * Constants defined here take precedence over the app's constants.php
 * because auto_prepend_file runs before the application bootstrap.
 */
if (defined('_OCOMPOSE_ENV_LOADED')) return;
define('_OCOMPOSE_ENV_LOADED', true);

// ── Suppress "Constant already defined" notices from the app ──
$_ocompose_prev_handler = set_error_handler(function ($severity, $message, $file, $line) {
    // Silence E_NOTICE / E_WARNING for constant redefinition
    if (($severity === E_NOTICE || $severity === E_WARNING)
        && strpos($message, 'Constant') !== false
        && strpos($message, 'already defined') !== false
    ) {
        return true; // swallow
    }
    // Delegate everything else to the previous handler or PHP default
    global $_ocompose_prev_handler;
    if (is_callable($_ocompose_prev_handler)) {
        return call_user_func($_ocompose_prev_handler, $severity, $message, $file, $line);
    }
    return false;
});

// ── Database constants ──
PREPEND_HEADER

        cat >> "$prepend_file" <<PREPEND_DB
define('BDD_HOST', getenv('MYSQL_HOST') ?: '${MYSQL_HOST:-mysql}');
define('BDD_USER', getenv('MYSQL_USER') ?: '${MYSQL_USER:-root}');
define('BDD_PWD',  getenv('MYSQL_PASSWORD') ?: '${MYSQL_PASSWORD:-}');
PREPEND_DB

        cat >> "$prepend_file" <<PREPEND_PATHS

// ── Application paths ──
define('APP_ROOT', getenv('CI3_APP_ROOT') ?: '${effective_app_root}');

PREPEND_PATHS

        # Extra constants
        if [[ -n "$extra_constants_php" ]]; then
            cat >> "$prepend_file" <<PREPEND_EXTRA
// ── Extra constant overrides from CI3_EXTRA_CONSTANTS ──
\$_ocompose_extras = array(
${extra_constants_php});
foreach (\$_ocompose_extras as \$_oc_name => \$_oc_val) {
    if (\$_oc_val !== false && !defined(\$_oc_name)) {
        define(\$_oc_name, \$_oc_val);
    }
}
unset(\$_ocompose_extras, \$_oc_name, \$_oc_val);

PREPEND_EXTRA
        fi

        cat >> "$prepend_file" <<PREPEND_CI_CONFIG
// ── CI3 \$config overrides (base_url, session) ──
// These are picked up by a post-system hook or by direct patching
// of config.php at load time via the CI3 config override mechanism.
// CI3 supports application/config/{ENVIRONMENT}/ overrides, but
// the simplest portable approach is a global that config.php reads.
\$GLOBALS['_ocompose_ci3_config'] = array(
    'base_url'       => getenv('CI3_BASE_URL') ?: getenv('APP_BASE_URL') ?: '${base_url}',
    'sess_save_path' => getenv('CI3_SESSION_SAVE_PATH') ?: '${session_path}',
);
PREPEND_CI_CONFIG

        # Generate the CI3 config override files in the environment config dir.
        # CI3 loads files from application/config/{ENVIRONMENT}/ automatically.
        # We use 'development' because most CI3 apps already handle it in their
        # index.php switch statement.
        local ci3_env_config_dir="$ci3_root/application/config/development"
        mkdir -p "$ci3_env_config_dir"

        local ocompose_marker="// --- ocompose auto-config ---"

        # config.php — append our overrides at the end so they win.
        # If the file exists (from the repo), we inject at the bottom.
        # If it has our marker already, replace the injected block.
        if [[ -f "$ci3_env_config_dir/config.php" ]]; then
            # Remove previous ocompose block if present (use # as sed delimiter to avoid clash with //)
            sed -i "\#${ocompose_marker}#,\$d" "$ci3_env_config_dir/config.php"
        else
            cat > "$ci3_env_config_dir/config.php" <<'CI3_CONFIG_HEADER'
<?php
defined('BASEPATH') OR exit('No direct script access allowed');
CI3_CONFIG_HEADER
        fi
        cat >> "$ci3_env_config_dir/config.php" <<OCOMPOSE_CONFIG_BLOCK
${ocompose_marker}
// Auto-injected by ocompose on every 'up' / 'restart'.
if (isset(\$GLOBALS['_ocompose_ci3_config'])) {
    foreach (\$GLOBALS['_ocompose_ci3_config'] as \$_oc_key => \$_oc_val) {
        \$config[\$_oc_key] = \$_oc_val;
    }
    unset(\$_oc_key, \$_oc_val);
}
OCOMPOSE_CONFIG_BLOCK

        # database.php — always overwrite with Docker-aware version.
        # The app's repo version typically has hardcoded localhost values.
        cat > "$ci3_env_config_dir/database.php" <<CI3_DOCKER_DB
<?php
defined('BASEPATH') OR exit('No direct script access allowed');
${ocompose_marker}
// Auto-generated by ocompose on every 'up' / 'restart'.
// Connects to the Docker DB container using env vars with fallbacks.
\$active_group = 'default';
\$query_builder = TRUE;

\$db['default'] = array(
    'dsn'      => '',
    'hostname' => getenv('MYSQL_HOST') ?: '${MYSQL_HOST:-mysql}',
    'username' => getenv('MYSQL_USER') ?: '${MYSQL_USER:-root}',
    'password' => getenv('MYSQL_PASSWORD') ?: '${MYSQL_PASSWORD:-}',
    'database' => getenv('MYSQL_DATABASE') ?: '${MYSQL_DATABASE:-app_db}',
    'dbdriver' => 'mysqli',
    'dbprefix' => '',
    'pconnect' => FALSE,
    'db_debug' => FALSE,
    'cache_on' => FALSE,
    'cachedir' => '',
    'char_set' => 'utf8',
    'dbcollat' => 'utf8_general_ci',
    'swap_pre' => '',
    'encrypt'  => FALSE,
    'compress' => FALSE,
    'stricton' => FALSE,
    'failover' => array(),
    'save_queries' => TRUE
);
CI3_DOCKER_DB

        # Force ENVIRONMENT = 'development' so CI3 loads config/development/*.
        # The prepend file runs before index.php, so this define() takes
        # precedence over any HTTP_HOST-based logic in the entry point.
        cat >> "$prepend_file" <<'PREPEND_ENVIRONMENT'

// ── Force CI3 environment to 'development' ──
// Defining ENVIRONMENT here (before index.php) takes precedence over
// any HTTP_HOST-based or CI_ENV-based logic in the application's entry point.
if (!defined('ENVIRONMENT')) {
    define('ENVIRONMENT', 'development');
}
PREPEND_ENVIRONMENT

        # constants.php — only generate if missing; load app's own constants
        if [[ ! -f "$ci3_env_config_dir/constants.php" ]]; then
            cat > "$ci3_env_config_dir/constants.php" <<'CI3_DEV_CONSTANTS'
<?php
defined('BASEPATH') OR exit('No direct script access allowed');
/**
 * Auto-generated by ocompose.
 * Placeholder constants file for development environment.
 * Add your app-specific constants here, or replace this file.
 * Constants already defined by .ocompose.env.php (BDD_HOST, BDD_USER, etc.)
 * are silently preserved — PHP skips duplicate define() calls.
 */
CI3_DEV_CONSTANTS
        fi

        log_verbose "   ${GREEN}✓${NC} Generated ${prepend_file#"$INSTANCES_DIR/$INSTANCE/"}"
        log_verbose "   ${GREEN}✓${NC} Generated application/config/development/ overrides"
    done

    # Ensure php.ini has auto_prepend_file set
    local php_ini="$instance_dir/config/php/php.ini"
    if [[ -f "$php_ini" ]]; then
        # Determine the prepend path inside the container
        local first_root="${ci3_roots[0]}"
        local relative_first="${first_root#"$www_dir"}"
        relative_first="${relative_first%/}"
        local prepend_docker_path="/var/www/html${relative_first}/.ocompose.env.php"

        if grep -q "^auto_prepend_file" "$php_ini"; then
            sed -i "s|^auto_prepend_file.*|auto_prepend_file = ${prepend_docker_path}|" "$php_ini"
        else
            echo "" >> "$php_ini"
            echo "; ocompose: CI3 environment injection" >> "$php_ini"
            echo "auto_prepend_file = ${prepend_docker_path}" >> "$php_ini"
        fi
    fi

    # Create session directory inside www so the Dockerfile WORKDIR owns it,
    # OR rely on /tmp.  We'll create a small init script that runs in the container.
    # For /tmp-based sessions, PHP can create the dir itself — just needs the
    # directory to exist.  We ensure it via an entrypoint addition.
    log_verbose "   ${GREEN}✓${NC} Session save path: ${session_path}"
}

# ── Parse VHOSTS and resolve legacy APP_PORT / NGINX_DOCUMENT_ROOT ──
# Sets RESOLVED_VHOSTS as a newline-separated list of "port:docroot" entries.
resolve_vhosts() {
    local vhosts="${VHOSTS:-}"

    # Backward compat: if VHOSTS is empty, build from legacy vars
    if [[ -z "$vhosts" ]]; then
        local port="${APP_PORT:-8000}"
        local docroot="${NGINX_DOCUMENT_ROOT:-}"
        vhosts="${port}:${docroot}"
    fi

    RESOLVED_VHOSTS=""
    IFS=',' read -ra entries <<< "$vhosts"
    for entry in "${entries[@]}"; do
        entry="$(echo "$entry" | xargs)"  # trim whitespace
        [[ -z "$entry" ]] && continue
        RESOLVED_VHOSTS="${RESOLVED_VHOSTS}${entry}"$'\n'
    done
}

# ── Generate nginx config with one server block per vhost ──
generate_vhosts_config() {
    local instance_dir="$INSTANCES_DIR/$INSTANCE"
    local nginx_target="$instance_dir/config/nginx/default.conf"
    local override_target="$instance_dir/docker-compose.vhosts.yml"

    resolve_vhosts

    # ── nginx default.conf ──
    local nginx_conf=""
    local internal_port=80
    local compose_ports=""

    while IFS= read -r vhost_entry; do
        [[ -z "$vhost_entry" ]] && continue

        local host_port="${vhost_entry%%:*}"
        local docroot="${vhost_entry#*:}"

        # Normalize document root
        docroot="${docroot#/}"
        [[ -n "$docroot" ]] && docroot="/${docroot}"

        local runtime="${APP_RUNTIME:-php}"
        local upstream_block=""

        case "$runtime" in
            php)
                upstream_block="
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass php:9000;
        fastcgi_index index.php;
    }"
                ;;
            node)
                upstream_block="
    location @backend {
        proxy_pass http://node:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }"
                ;;
            python)
                upstream_block="
    location @backend {
        proxy_pass http://python:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }"
                ;;
        esac

        local try_files_directive
        case "$runtime" in
            php)    try_files_directive="try_files \$uri \$uri/ /index.php?\$query_string;" ;;
            node|python) try_files_directive="try_files \$uri \$uri/ @backend;" ;;
            static) try_files_directive="try_files \$uri \$uri/ =404;" ;;
        esac

        nginx_conf+="server {
    listen ${internal_port};
    server_name _;

    root /var/www/html${docroot};
    index index.php index.html index.htm;

    location / {
        ${try_files_directive}
    }
${upstream_block}

    location ~ /\.(?!well-known).* {
        deny all;
    }
}

"
        compose_ports+="      - \"${host_port}:${internal_port}\""$'\n'
        internal_port=$(( internal_port + 1 ))
    done <<< "$RESOLVED_VHOSTS"

    echo -n "$nginx_conf" > "$nginx_target"

    # ── docker-compose.vhosts.yml (override for dynamic port mappings) ──
    {
        echo "# Auto-generated by ocompose — do not edit manually."
        echo "# Regenerated on every 'up' / 'restart' from VHOSTS in .env."
        echo "services:"
        echo "  nginx:"
        echo "    ports:"
        printf '%s' "$compose_ports"
    } > "$override_target"
}

ensure_instance_files() {
    local instance_dir="$INSTANCES_DIR/$INSTANCE"

    mkdir -p "$instance_dir/www"
    mkdir -p "$instance_dir/config/nginx" "$instance_dir/config/php" "$instance_dir/config/mysql" "$instance_dir/config/mariadb"
    mkdir -p "$instance_dir/config/ssh"
    mkdir -p "$instance_dir/seed-state"

    copy_if_missing "$PROJECT_DIR/www/index.php" "$instance_dir/www/index.php"

    # ── Generate nginx config + compose override from VHOSTS ──
    generate_vhosts_config

    copy_if_missing "$PROJECT_DIR/config/php/php.ini" "$instance_dir/config/php/php.ini"
    copy_if_missing "$PROJECT_DIR/config/mysql/my.cnf" "$instance_dir/config/mysql/my.cnf"
    copy_if_missing "$PROJECT_DIR/config/mariadb/my.cnf" "$instance_dir/config/mariadb/my.cnf"

    # Ensure workspace has proper permissions
    chmod -R 777 "$instance_dir/www" 2>/dev/null || true

    # Configure CodeIgniter if present
    configure_codeigniter_env
    configure_ci3_env
}

sync_instance_env_defaults() {
    local env_file="$INSTANCES_DIR/$INSTANCE/.env"

    [[ -f "$env_file" ]] || return 0

    while IFS= read -r template_line; do
        local trimmed_line key

        trimmed_line="${template_line%$'\r'}"
        [[ -z "$trimmed_line" || "$trimmed_line" == \#* || "$trimmed_line" != *=* ]] && continue

        key="${trimmed_line%%=*}"
        if ! grep -qE "^${key}=" "$env_file"; then
            printf '\n%s\n' "$trimmed_line" >> "$env_file"
        fi
    done < "$PROJECT_DIR/.env.example"
}

# ── Load instance env ──
load_instance_env() {
    local env_file="$INSTANCES_DIR/$INSTANCE/.env"
    local normalized_env_file
    if [[ ! -f "$env_file" ]]; then
        echo -e "${RED}✗ Instance '$INSTANCE' not found.${NC}"
        echo "  Run: ocompose.sh $INSTANCE init"
        exit 1
    fi

    sync_instance_env_defaults

    # Accept .env files created on Windows by stripping CRLF before sourcing.
    normalized_env_file="$(normalize_env_file)"

    set -a
    source "$normalized_env_file"
    set +a
    rm -f "$normalized_env_file"
    export PROJECT_NAME="$INSTANCE"

    resolve_legacy_vars
    validate_db_version
    ensure_instance_files
}

# ── Build active profiles ──
get_profiles() {
    local profiles=""
    local runtime="${APP_RUNTIME:-php}"
    local engine="${DB_ENGINE:-mysql}"

    # App runtime
    case "$runtime" in
        php)    profiles="$profiles --profile php" ;;
        node)   profiles="$profiles --profile node" ;;
        python) profiles="$profiles --profile python" ;;
        static) profiles="$profiles --profile static" ;;
    esac

    # Database engine
    case "$engine" in
        mysql)   profiles="$profiles --profile mysql" ;;
        mariadb) profiles="$profiles --profile mariadb" ;;
        postgres) profiles="$profiles --profile postgres" ;;
    esac

    # Database admin
    if [[ "${DB_ADMIN_ENABLED:-false}" == "true" ]]; then
        case "$engine" in
            mysql|mariadb) profiles="$profiles --profile phpmyadmin" ;;
            postgres)      profiles="$profiles --profile pgadmin" ;;
        esac
    fi

    # Redis
    [[ "${REDIS_ENABLED:-false}" == "true" ]] && profiles="$profiles --profile redis"

    echo "$profiles"
}

compose_cmd() {
    local profiles
    local normalized_env_file
    local vhosts_override="$INSTANCES_DIR/$INSTANCE/docker-compose.vhosts.yml"
    profiles=$(get_profiles)

    normalized_env_file="$(normalize_env_file)"

    local compose_files=(-f "$PROJECT_DIR/docker-compose.yml")
    if [[ -f "$vhosts_override" ]]; then
        compose_files+=(-f "$vhosts_override")
    fi

    # In quiet mode (web UI), suppress Docker build/pull progress noise
    if [[ "$OCOMPOSE_QUIET" == "true" ]]; then
        docker compose \
            "${compose_files[@]}" \
            --env-file "$normalized_env_file" \
            -p "$INSTANCE" \
            $profiles \
            "$@" > /dev/null 2>&1
    else
        docker compose \
            "${compose_files[@]}" \
            --env-file "$normalized_env_file" \
            -p "$INSTANCE" \
            $profiles \
            "$@"
    fi
    rm -f "$normalized_env_file"
}

# ════════════════════════════════════════════
# Commands
# ════════════════════════════════════════════

cmd_init() {
    require_instance
    local instance_dir="$INSTANCES_DIR/$INSTANCE"
    local auto_confirm="false"

    if has_flag "--yes" "$@"; then
        auto_confirm="true"
    fi

    if [[ -d "$instance_dir" ]]; then
        echo -e "${YELLOW}⚠  Instance '$INSTANCE' already exists at $instance_dir${NC}"
        if [[ "$auto_confirm" != "true" ]]; then
            read -p "   Overwrite .env? (y/N): " confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0
        fi
    fi

    mkdir -p "$instance_dir/www"
    mkdir -p "$instance_dir/config/nginx" "$instance_dir/config/php" "$instance_dir/config/mysql" "$instance_dir/config/mariadb"
    mkdir -p "$instance_dir/config/ssh"
    mkdir -p "$instance_dir/seed-state"

    # Copy template and inject instance name
    sed "s/^PROJECT_NAME=.*/PROJECT_NAME=$INSTANCE/" \
        "$PROJECT_DIR/.env.example" > "$instance_dir/.env"

    # Auto-assign unique ports based on instance count
    local count
    count=$(find "$INSTANCES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    local offset=$(( (count - 1) * 10 ))

    sed -i.bak \
        -e "s/^VHOSTS=.*/VHOSTS=$(( 8000 + offset )):/" \
        -e "s/^DB_PORT=.*/DB_PORT=$(( 3306 + offset ))/" \
        -e "s/^DB_ADMIN_PORT=.*/DB_ADMIN_PORT=$(( 8080 + offset ))/" \
        -e "s/^WORKSPACE_SSH_PORT=.*/WORKSPACE_SSH_PORT=$(( 2222 + offset ))/" \
        -e "s/^REDIS_PORT=.*/REDIS_PORT=$(( 6379 + offset ))/" \
        "$instance_dir/.env"
    rm -f "$instance_dir/.env.bak"

    # Copy default index.php
    ensure_instance_files

    # Generate SSH keypair for the instance
    if [[ ! -f "$instance_dir/config/ssh/id_ed25519" ]]; then
        ssh-keygen -t ed25519 -f "$instance_dir/config/ssh/id_ed25519" -N "" -C "ocompose-$INSTANCE" -q
        cp "$instance_dir/config/ssh/id_ed25519.pub" "$instance_dir/config/ssh/authorized_keys"
        chmod 600 "$instance_dir/config/ssh/authorized_keys"
    fi

    local ssh_port
    ssh_port=$(grep "^WORKSPACE_SSH_PORT=" "$instance_dir/.env" | cut -d= -f2)

    echo -e "${GREEN}✅ Instance '$INSTANCE' created!${NC}"
    echo -e "   Config: $instance_dir/.env"
    echo -e "   Webroot: $instance_dir/www/"
    echo -e "   Runtime config: $instance_dir/config/"
    echo -e "   DB seed state: $instance_dir/seed-state/"
    echo ""
    echo -e "   ${CYAN}SSH private key: $instance_dir/config/ssh/id_ed25519${NC}"
    echo -e "   ${CYAN}Connect with:    ssh -i $instance_dir/config/ssh/id_ed25519 -p ${ssh_port:-2222} developer@<host>${NC}"
    echo ""
    echo -e "   ${CYAN}Edit the .env file, then run:${NC}"
    echo -e "   ./scripts/ocompose.sh $INSTANCE up"
}

cmd_ui() {
    local action="start"
    local port="${OCOMPOSE_UI_PORT:-8787}"

    if [[ $# -gt 0 ]]; then
        case "$1" in
            start|stop|status|restart)
                action="$1"
                shift
                ;;
        esac
    fi

    if [[ $# -gt 0 ]]; then
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --username)
                    export OCOMPOSE_UI_USERNAME="$2"
                    shift 2
                    ;;
                --password)
                    export OCOMPOSE_UI_PASSWORD="$2"
                    shift 2
                    ;;
                *)
                    port="$1"
                    shift
                    ;;
            esac
        done
    fi

    if ! command -v node >/dev/null 2>&1; then
        echo -e "${RED}✗ Error: Node.js is required to run the web UI.${NC}"
        exit 1
    fi

    case "$action" in
        start)
            if is_ui_running; then
                local current_pid
                current_pid="$(tr -d '[:space:]' < "$UI_PID_FILE")"
                echo -e "${YELLOW}⚠  ocompose web UI is already running (PID: ${current_pid}).${NC}"
                echo -e "   URL:  http://localhost:${port}"
                echo -e "   Hint: ./scripts/ocompose.sh ui restart"
                echo -e "   Stop: ./scripts/ocompose.sh ui stop"
                return 0
            fi

            load_ui_auth

            if [[ -n "${OCOMPOSE_UI_USERNAME:-}" && -n "${OCOMPOSE_UI_PASSWORD:-}" ]]; then
                write_ui_auth_file "$OCOMPOSE_UI_USERNAME" "$OCOMPOSE_UI_PASSWORD"
            fi

            echo -e "${CYAN}Launching ocompose web UI in the background on http://localhost:${port}${NC}"
            nohup env \
                OCOMPOSE_UI_PORT="$port" \
                OCOMPOSE_UI_USERNAME="$OCOMPOSE_UI_USERNAME" \
                OCOMPOSE_UI_PASSWORD="$OCOMPOSE_UI_PASSWORD" \
                node "$PROJECT_DIR/web-ui/server.js" > "$UI_LOG_FILE" 2>&1 &
            local ui_pid=$!
            echo "$ui_pid" > "$UI_PID_FILE"
            sleep 1

            if kill -0 "$ui_pid" 2>/dev/null; then
                echo -e "${GREEN}✅ Web UI started.${NC}"
                echo -e "   URL:  http://localhost:${port}"
                echo -e "   PID:  ${ui_pid}"
                echo -e "   Log:  $UI_LOG_FILE"
                echo -e "   User: ${OCOMPOSE_UI_USERNAME}"
                echo -e "   Pass: ${OCOMPOSE_UI_PASSWORD}"
                echo -e "   Auth: $UI_AUTH_FILE"
                echo -e "   Stop: ./scripts/ocompose.sh ui stop"
                return 0
            fi

            rm -f "$UI_PID_FILE"
            echo -e "${RED}✗ Failed to start the web UI.${NC}"
            [[ -f "$UI_LOG_FILE" ]] && tail -n 20 "$UI_LOG_FILE"
            exit 1
            ;;
        stop)
            if ! is_ui_running; then
                echo -e "${YELLOW}⚠  ocompose web UI is not running.${NC}"
                return 0
            fi

            local ui_pid
            ui_pid="$(tr -d '[:space:]' < "$UI_PID_FILE")"
            kill "$ui_pid" 2>/dev/null || true
            rm -f "$UI_PID_FILE"
            echo -e "${GREEN}✅ Web UI stopped.${NC}"
            ;;
        restart)
            if is_ui_running; then
                local ui_pid
                ui_pid="$(tr -d '[:space:]' < "$UI_PID_FILE")"
                kill "$ui_pid" 2>/dev/null || true
                rm -f "$UI_PID_FILE"
                echo -e "${CYAN}↻ Restarting ocompose web UI...${NC}"
            else
                echo -e "${CYAN}Launching ocompose web UI...${NC}"
            fi

            cmd_ui start "$port" "$@"
            ;;
        status)
            if is_ui_running; then
                local ui_pid
                ui_pid="$(tr -d '[:space:]' < "$UI_PID_FILE")"
                load_ui_auth
                echo -e "${GREEN}✅ ocompose web UI is running.${NC}"
                echo -e "   PID: ${ui_pid}"
                echo -e "   Log: $UI_LOG_FILE"
                echo -e "   User: ${OCOMPOSE_UI_USERNAME}"
                echo -e "   Auth: $UI_AUTH_FILE"
            else
                echo -e "${YELLOW}⚠  ocompose web UI is not running.${NC}"
            fi
            ;;
    esac
}

cmd_up() {
    require_instance
    load_instance_env
    bootstrap_instance_git_repo

    # Re-run CI3/CI4 detection after git clone (first run: www/ was empty during load_instance_env)
    configure_codeigniter_env
    configure_ci3_env

    log_verbose "${CYAN}🐳 Starting instance '${BOLD}$INSTANCE${NC}${CYAN}'...${NC}"
    compose_cmd up -d --build "$@"

    # Ensure DB + user exist regardless of seed file
    local engine="${DB_ENGINE:-mysql}"
    if [[ "$engine" != "none" ]]; then
        if wait_for_db_ready; then
            ensure_db_exists || log_verbose "${YELLOW}⚠  Could not ensure database exists (non-fatal).${NC}"
            grant_db_user_access || log_verbose "${YELLOW}⚠  Could not grant DB user access (non-fatal).${NC}"
        else
            log_verbose "${YELLOW}⚠  Database not ready yet — skipping DB setup. It may need more time to initialize.${NC}"
        fi
    fi

    import_db_seed_if_configured
    echo ""
    echo -e "${GREEN}✅ Instance '$INSTANCE' is running!${NC}"
    log_verbose "   Shell:      ./scripts/ocompose.sh $INSTANCE shell"

    local runtime="${APP_RUNTIME:-php}"
    if [[ "$runtime" != "none" ]]; then
        resolve_vhosts
        while IFS= read -r vhost_entry; do
            [[ -z "$vhost_entry" ]] && continue
            local vhost_port="${vhost_entry%%:*}"
            local vhost_docroot="${vhost_entry#*:}"
            [[ -z "$vhost_docroot" ]] && vhost_docroot="/"
            log_verbose "   App:        http://localhost:${vhost_port}  →  ${vhost_docroot}"
        done <<< "$RESOLVED_VHOSTS"
    fi

    local engine="${DB_ENGINE:-mysql}"
    [[ "$engine" != "none" ]] && log_verbose "   Database:   ${engine} @ localhost:${DB_PORT:-3306}"

    if [[ "${DB_ADMIN_ENABLED:-false}" == "true" ]]; then
        case "$engine" in
            mysql|mariadb) log_verbose "   phpMyAdmin: http://localhost:${DB_ADMIN_PORT:-8080}" ;;
            postgres)      log_verbose "   pgAdmin:    http://localhost:${DB_ADMIN_PORT:-5050}" ;;
        esac
    fi

    [[ "${REDIS_ENABLED:-false}" == "true" ]] && log_verbose "   Redis:      localhost:${REDIS_PORT:-6379}"
}

cmd_down() {
    require_instance
    load_instance_env
    log_verbose "${CYAN}🛑 Stopping instance '$INSTANCE'...${NC}"
    compose_cmd down "$@"
    echo -e "${GREEN}✅ Stopped.${NC}"
}

cmd_restart() {
    cmd_down
    cmd_up
}

cmd_shell() {
    require_instance
    load_instance_env
    echo -e "${CYAN}🔌 Connecting to '${INSTANCE}' workspace...${NC}"
    docker exec -it "${INSTANCE}_workspace" bash
}

cmd_ssh_info() {
    require_instance
    load_instance_env
    local instance_dir="$INSTANCES_DIR/$INSTANCE"
    local key_file="$instance_dir/config/ssh/id_ed25519"
    local auth_file="$instance_dir/config/ssh/authorized_keys"
    local ssh_port="${WORKSPACE_SSH_PORT:-2222}"
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    echo -e "${CYAN}🔑 SSH info for '${INSTANCE}':${NC}"
    echo ""
    echo -e "   Port:           ${BOLD}${ssh_port}${NC}"
    echo -e "   User:           ${BOLD}${WORKSPACE_USER:-developer}${NC}"
    echo -e "   Private key:    $key_file"
    echo -e "   Authorized keys: $auth_file"
    echo ""
    echo -e "   ${CYAN}Connect:${NC}"
    echo -e "   ssh -i $key_file -p $ssh_port ${WORKSPACE_USER:-developer}@$hostname"
    echo ""
    echo -e "   ${CYAN}Give a dev access (append their public key):${NC}"
    echo -e "   cat their_key.pub >> $auth_file"
}

cmd_status() {
    require_instance
    load_instance_env
    compose_cmd ps
}

cmd_logs() {
    require_instance
    load_instance_env
    compose_cmd logs -f "$@"
}

cmd_destroy() {
    require_instance
    local auto_confirm="false"

    if [[ ! -d "$INSTANCES_DIR/$INSTANCE" ]]; then
        echo -e "${RED}✗ Instance '$INSTANCE' not found.${NC}"
        exit 1
    fi

    if has_flag "--yes" "$@"; then
        auto_confirm="true"
    fi

    echo -e "${RED}⚠  This will destroy instance '$INSTANCE' (containers, volumes, config).${NC}"
    if [[ "$auto_confirm" != "true" ]]; then
        read -p "   Are you sure? (y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0
    fi

    if [[ -f "$INSTANCES_DIR/$INSTANCE/.env" ]]; then
        load_instance_env
        compose_cmd down -v 2>/dev/null || true
    fi

    # Files created by Docker containers are owned by root; use a temporary
    # container to delete the *contents* of the instance directory.
    docker run --rm -v "$INSTANCES_DIR/$INSTANCE:/target" alpine sh -c 'rm -rf /target/* /target/.[!.]* /target/..?*' 2>/dev/null || true
    # Now the directory should be empty and removable by the current user.
    rm -rf "$INSTANCES_DIR/$INSTANCE" 2>/dev/null || true

    # Final check: if stubborn files remain, tell the user.
    if [[ -d "$INSTANCES_DIR/$INSTANCE" ]] && [[ -n "$(ls -A "$INSTANCES_DIR/$INSTANCE" 2>/dev/null)" ]]; then
        echo -e "${YELLOW}⚠  Some files in '$INSTANCES_DIR/$INSTANCE' could not be removed.${NC}"
        echo "  You may need to run:  sudo rm -rf $INSTANCES_DIR/$INSTANCE"
    else
        rm -df "$INSTANCES_DIR/$INSTANCE" 2>/dev/null || true
        echo -e "${GREEN}✅ Instance '$INSTANCE' destroyed.${NC}"
    fi
}

cmd_list() {
    echo -e "${CYAN}📦 ocompose instances:${NC}"
    echo ""
    if [[ ! -d "$INSTANCES_DIR" ]] || [[ -z "$(ls -A "$INSTANCES_DIR" 2>/dev/null)" ]]; then
        echo -e "   ${YELLOW}(none)${NC}"
        echo "   Create one with: ocompose.sh <name> init"
        return
    fi

    printf "   ${BOLD}%-20s %-12s %-10s %-10s %-18s %-10s %-10s %-10s${NC}\n" "INSTANCE" "STATUS" "RUNTIME" "DB" "APP" "DB PORT" "ADMIN" "SSH"
    for dir in "$INSTANCES_DIR"/*/; do
        local name
        name=$(basename "$dir")
        local env_file="$dir/.env"
        local status="stopped"

        if docker ps --format '{{.Names}}' | grep -q "^${name}_workspace$"; then
            status="${GREEN}running${NC}"
        else
            status="${RED}stopped${NC}"
        fi

        local runtime="-" db_engine="-" app_ports="-" db_port="-" admin_port="-" ssh_port="-"
        if [[ -f "$env_file" ]]; then
            # Runtime
            runtime=$(grep "^APP_RUNTIME=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "")
            if [[ -z "$runtime" ]]; then
                # Legacy fallback
                local php_enabled
                php_enabled=$(grep "^PHP_ENABLED=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "")
                [[ "$php_enabled" == "true" ]] && runtime="php" || runtime="-"
            fi

            # DB engine
            db_engine=$(grep "^DB_ENGINE=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "")
            if [[ -z "$db_engine" ]]; then
                local mysql_enabled
                mysql_enabled=$(grep "^MYSQL_ENABLED=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "")
                [[ "$mysql_enabled" == "true" ]] && db_engine="mysql" || db_engine="-"
            fi

            # Vhosts
            local vhosts_raw
            vhosts_raw=$(grep "^VHOSTS=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "")
            if [[ -n "$vhosts_raw" ]]; then
                local port_list=""
                IFS=',' read -ra vh_entries <<< "$vhosts_raw"
                for vh in "${vh_entries[@]}"; do
                    vh="$(echo "$vh" | xargs)"
                    [[ -z "$vh" ]] && continue
                    local p="${vh%%:*}"
                    port_list="${port_list:+$port_list,}$p"
                done
                app_ports="${port_list:-"-"}"
            else
                app_ports=$(grep "^APP_PORT=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "-")
                [[ -z "$app_ports" ]] && app_ports="-"
            fi

            db_port=$(grep "^DB_PORT=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "")
            [[ -z "$db_port" ]] && db_port=$(grep "^MYSQL_PORT=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "-")
            admin_port=$(grep "^DB_ADMIN_PORT=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "")
            [[ -z "$admin_port" ]] && admin_port=$(grep "^PHPMYADMIN_PORT=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "-")
            ssh_port=$(grep "^WORKSPACE_SSH_PORT=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "-")
        fi

        printf "   %-20s %-22b %-10s %-10s %-18s %-10s %-10s %-10s\n" "$name" "$status" "$runtime" "$db_engine" "$app_ports" "$db_port" "$admin_port" "$ssh_port"
    done
}

cmd_help() {
    echo ""
    echo -e "${CYAN}${BOLD}ocompose${NC} — Reproducible Docker Mini OS (Multi-Instance)"
    echo ""
    echo "Usage: ocompose.sh <instance> <command> [options]"
    echo "       ocompose.sh list"
    echo "       ocompose.sh ui [start] [port]"
    echo "       ocompose.sh ui stop"
    echo "       ocompose.sh ui restart [port]"
    echo "       ocompose.sh ui status"
    echo "       ocompose.sh ui [port] --username <name> --password <pass>"
    echo "       ocompose.sh install-cli [bin-dir]"
    echo "       ocompose.sh uninstall-cli [bin-dir]"
    echo ""
    echo "Commands:"
    echo "  init       Create a new instance"
    echo "  up         Start the instance"
    echo "  down       Stop the instance"
    echo "  restart    Restart the instance"
    echo "  shell      Open bash in the workspace"
    echo "  ssh-info   Show SSH connection details"
    echo "  status     Show container status"
    echo "  logs       Tail logs"
    echo "  destroy    Remove instance entirely"
    echo "  list       List all instances"
    echo "  ui         Manage the web admin UI"
    echo "  install-cli     Install the 'ocompose' command"
    echo "  uninstall-cli   Remove the installed 'ocompose' command"
    echo "  help       Show this help"
    echo ""
    echo "Examples:"
    echo "  ocompose.sh client-a init       # Create instance"
    echo "  ocompose.sh client-a up         # Start it"
    echo "  ocompose.sh client-a shell      # SSH into workspace"
    echo "  ocompose.sh blog init           # Create another instance"
    echo "  ocompose.sh list                # See all instances"
    echo "  ocompose.sh ui                  # Start the web admin in background"
    echo "  ocompose.sh ui restart          # Restart the web admin"
    echo "  ocompose.sh ui stop             # Stop the web admin"
    echo "  ocompose.sh ui 8787 --username admin --password secret"
    echo "  ocompose.sh install-cli         # Install 'ocompose' into ~/.local/bin"
    echo ""
}

# ════════════════════════════════════════════
# Main
# ════════════════════════════════════════════

# Handle global commands (no instance needed)
case "${1:-help}" in
    list) cmd_list; exit 0 ;;
    help) cmd_help; exit 0 ;;
    ui) shift; cmd_ui "$@"; exit 0 ;;
    install-cli) shift; cmd_install_cli "$@"; exit 0 ;;
    uninstall-cli) shift; cmd_uninstall_cli "$@"; exit 0 ;;
esac

# Instance-specific commands
INSTANCE="${1:-}"
COMMAND="${2:-help}"
shift 2 2>/dev/null || true

case "$COMMAND" in
    init)    cmd_init "$@" ;;
    up)      cmd_up "$@" ;;
    down)    cmd_down "$@" ;;
    restart) cmd_restart ;;
    shell)   cmd_shell ;;
    ssh-info) cmd_ssh_info ;;
    status)  cmd_status ;;
    logs)    cmd_logs "$@" ;;
    destroy) cmd_destroy "$@" ;;
    help|*)  cmd_help ;;
esac