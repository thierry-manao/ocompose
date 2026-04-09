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

resolve_mysql_seed_file() {
    local seed_file="${MYSQL_SEED_FILE:-}"
    local base_name

    [[ -n "$seed_file" ]] || return 0

    base_name="$(basename "$seed_file")"
    if [[ "$base_name" != "$seed_file" ]]; then
        echo -e "${RED}✗ MYSQL_SEED_FILE must be a filename from the db directory for '$INSTANCE'.${NC}"
        echo "  Value: $seed_file"
        exit 1
    fi

    echo "$PROJECT_DIR/db/$seed_file"
}

wait_for_mysql_ready() {
    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "${INSTANCE}_mysql" mysqladmin ping -h 127.0.0.1 -uroot --silent >/dev/null 2>&1; then
            return 0
        fi

        attempt=$((attempt + 1))
        sleep 2
    done

    echo -e "${RED}✗ MySQL did not become ready in time for '$INSTANCE'.${NC}"
    exit 1
}

ensure_mysql_database_exists() {
    if [[ ! "${MYSQL_DATABASE:-}" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo -e "${RED}✗ MYSQL_DATABASE contains unsupported characters for '$INSTANCE'.${NC}"
        echo "  Value: ${MYSQL_DATABASE:-}"
        echo "  Allowed characters: letters, numbers, underscore"
        exit 1
    fi

    local create_database_sql
    printf -v create_database_sql 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' "$MYSQL_DATABASE"

    docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "${INSTANCE}_mysql" \
        mysql -uroot -e "$create_database_sql"
}

grant_mysql_user_access() {
    if [[ ! "${MYSQL_DATABASE:-}" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo -e "${RED}✗ MYSQL_DATABASE contains unsupported characters for '$INSTANCE'.${NC}"
        exit 1
    fi

    if [[ ! "${MYSQL_USER:-}" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo -e "${RED}✗ MYSQL_USER contains unsupported characters for '$INSTANCE'.${NC}"
        echo "  Value: ${MYSQL_USER:-}"
        echo "  Allowed characters: letters, numbers, underscore"
        exit 1
    fi

    local escaped_password grant_sql
    escaped_password="$(escape_mysql_string_literal "${MYSQL_PASSWORD:-}")"
    grant_sql="CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${escaped_password}'; ALTER USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${escaped_password}'; GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%'; FLUSH PRIVILEGES;"

    docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "${INSTANCE}_mysql" \
        mysql -uroot -e "$grant_sql"
}

recreate_mysql_database() {
    if [[ ! "${MYSQL_DATABASE:-}" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo -e "${RED}✗ MYSQL_DATABASE contains unsupported characters for '$INSTANCE'.${NC}"
        echo "  Value: ${MYSQL_DATABASE:-}"
        echo "  Allowed characters: letters, numbers, underscore"
        exit 1
    fi

    local recreate_database_sql
    printf -v recreate_database_sql 'DROP DATABASE IF EXISTS `%s`; CREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' "$MYSQL_DATABASE" "$MYSQL_DATABASE"

    docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "${INSTANCE}_mysql" \
        mysql -uroot -e "$recreate_database_sql"
}

mysql_database_has_tables() {
    local count_tables_sql table_count
    printf -v count_tables_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '%s';" "$MYSQL_DATABASE"

    table_count="$(docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "${INSTANCE}_mysql" mysql -uroot -N -s -e "$count_tables_sql" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$table_count" && "$table_count" != "0" ]]
}

import_mysql_seed_if_configured() {
    local seed_path marker_file current_signature previous_signature
    local reseed_on_startup="${MYSQL_RESEED_ON_STARTUP:-true}"

    [[ "${MYSQL_ENABLED:-false}" == "true" ]] || return 0
    seed_path="$(resolve_mysql_seed_file)"
    [[ -n "$seed_path" ]] || return 0

    if [[ ! -f "$seed_path" ]]; then
        echo -e "${RED}✗ MYSQL_SEED_FILE does not exist in '$PROJECT_DIR/db' for '$INSTANCE'.${NC}"
        echo "  Expected file: $seed_path"
        exit 1
    fi

    wait_for_mysql_ready

    marker_file="$(seed_marker_file)"
    mkdir -p "$(seed_state_dir)"
    current_signature="${MYSQL_DATABASE}:${MYSQL_SEED_FILE}:$(compute_file_signature "$seed_path")"
    previous_signature="$(cat "$marker_file" 2>/dev/null || true)"

    if [[ "$reseed_on_startup" != "true" ]]; then
        ensure_mysql_database_exists
        grant_mysql_user_access
        if [[ "$current_signature" == "$previous_signature" ]] && mysql_database_has_tables; then
            return 0
        fi
    fi

    recreate_mysql_database
    grant_mysql_user_access

    echo -e "${CYAN}🗄 Re-seeding '${BOLD}${MYSQL_DATABASE}${NC}${CYAN}' from '${BOLD}${MYSQL_SEED_FILE}${NC}${CYAN}' for '${BOLD}$INSTANCE${NC}${CYAN}'...${NC}"
    case "$seed_path" in
        *.sql)
            docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "${INSTANCE}_mysql" mysql -uroot "$MYSQL_DATABASE" < "$seed_path"
            ;;
        *.sql.gz)
            gzip -cd "$seed_path" | docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "${INSTANCE}_mysql" mysql -uroot "$MYSQL_DATABASE"
            ;;
        *)
            echo -e "${RED}✗ Unsupported MYSQL_SEED_FILE format for '$INSTANCE'.${NC}"
            echo "  Supported files: .sql, .sql.gz"
            exit 1
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

    echo -e "${RED}✗ Cannot clone into '$workspace_dir' because it already contains files.${NC}"
    echo "  Remove the existing contents or use an empty instance workspace before enabling GIT_REPO."
    exit 1
}

checkout_instance_branch() {
    local workspace_dir="$1"
    local branch="$2"
    local repo_url="$3"

    [[ -z "$branch" ]] && return 0

    if git -C "$workspace_dir" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$workspace_dir" checkout "$branch"
        return 0
    fi

    if git -C "$workspace_dir" remote get-url origin >/dev/null 2>&1; then
        run_git_repo_command "$repo_url" -C "$workspace_dir" fetch origin "$branch" --prune
        git -C "$workspace_dir" checkout -B "$branch" --track "origin/$branch"
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
            echo -e "${YELLOW}⚠ Repository URL changed for '$INSTANCE'. Removing old workspace...${NC}"
            echo "  Old origin: $current_origin"
            echo "  New origin: $repo_url"
            rm -rf "$workspace_dir"
            mkdir -p "$workspace_dir"

            echo -e "${CYAN}📥 Cloning new repository for '${BOLD}$INSTANCE${NC}${CYAN}'...${NC}"
            if [[ -n "$branch" ]]; then
                run_git_repo_command "$repo_url" clone --branch "$branch" --single-branch "$repo_url" "$workspace_dir"
            else
                run_git_repo_command "$repo_url" clone "$repo_url" "$workspace_dir"
            fi

            echo -e "${CYAN}🔒 Setting workspace permissions (777)...${NC}"
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

        echo -e "${CYAN}📥 Cloning repository for '${BOLD}$INSTANCE${NC}${CYAN}'...${NC}"
        if [[ -n "$branch" ]]; then
            run_git_repo_command "$repo_url" clone --branch "$branch" --single-branch "$repo_url" "$workspace_dir"
        else
            run_git_repo_command "$repo_url" clone "$repo_url" "$workspace_dir"
        fi

        echo -e "${CYAN}🔒 Setting workspace permissions (777)...${NC}"
        chmod -R 777 "$workspace_dir" 2>/dev/null || true
    fi

    if [[ -n "$branch" ]]; then
        echo -e "${CYAN}🌿 Switching '${BOLD}$INSTANCE${NC}${CYAN}' to branch '${BOLD}$branch${NC}${CYAN}'...${NC}"
        checkout_instance_branch "$workspace_dir" "$branch" "$repo_url"
    fi

    # Set proper permissions for workspace files
    echo -e "${CYAN}🔒 Setting workspace permissions (777)...${NC}"
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

        base_url="http://${server_host}:${APP_PORT:-8000}/"
    fi
    [[ "$base_url" != */ ]] && base_url="${base_url}/"

    # Configure CodeIgniter .env
    echo -e "${CYAN}⚙️  Configuring CodeIgniter environment...${NC}"

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

ensure_instance_files() {
    local instance_dir="$INSTANCES_DIR/$INSTANCE"

    mkdir -p "$instance_dir/www"
    mkdir -p "$instance_dir/config/nginx" "$instance_dir/config/php" "$instance_dir/config/mysql"
    mkdir -p "$instance_dir/seed-state"

    copy_if_missing "$PROJECT_DIR/www/index.php" "$instance_dir/www/index.php"

    # Generate nginx config with document root
    local nginx_target="$instance_dir/config/nginx/default.conf"
    local document_root="${NGINX_DOCUMENT_ROOT:-}"
    [[ -n "$document_root" && "$document_root" != "/" ]] && document_root="/$document_root"
    document_root="${document_root#/}"
    [[ -n "$document_root" ]] && document_root="/$document_root"

    sed "s|__DOCUMENT_ROOT__|${document_root}|g" \
        "$PROJECT_DIR/config/nginx/default.conf" > "$nginx_target"

    copy_if_missing "$PROJECT_DIR/config/php/php.ini" "$instance_dir/config/php/php.ini"
    copy_if_missing "$PROJECT_DIR/config/mysql/my.cnf" "$instance_dir/config/mysql/my.cnf"

    # Ensure workspace has proper permissions
    chmod -R 777 "$instance_dir/www" 2>/dev/null || true

    # Configure CodeIgniter if present
    configure_codeigniter_env
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

    ensure_instance_files
}

# ── Build active profiles ──
get_profiles() {
    local profiles=""
    [[ "${PHP_ENABLED:-false}" == "true" ]]        && profiles="$profiles --profile php"
    [[ "${MYSQL_ENABLED:-false}" == "true" ]]       && profiles="$profiles --profile mysql"
    [[ "${PHPMYADMIN_ENABLED:-false}" == "true" ]]  && profiles="$profiles --profile phpmyadmin"
    echo "$profiles"
}

compose_cmd() {
    local profiles
    local normalized_env_file
    profiles=$(get_profiles)

    normalized_env_file="$(normalize_env_file)"
    docker compose \
        -f "$PROJECT_DIR/docker-compose.yml" \
        --env-file "$normalized_env_file" \
        -p "$INSTANCE" \
        $profiles \
        "$@"
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
    mkdir -p "$instance_dir/config/nginx" "$instance_dir/config/php" "$instance_dir/config/mysql"
    mkdir -p "$instance_dir/seed-state"

    # Copy template and inject instance name
    sed "s/^PROJECT_NAME=.*/PROJECT_NAME=$INSTANCE/" \
        "$PROJECT_DIR/.env.example" > "$instance_dir/.env"

    # Auto-assign unique ports based on instance count
    local count
    count=$(find "$INSTANCES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    local offset=$(( (count - 1) * 10 ))

    sed -i.bak \
        -e "s/^APP_PORT=.*/APP_PORT=$(( 8000 + offset ))/" \
        -e "s/^MYSQL_PORT=.*/MYSQL_PORT=$(( 3306 + offset ))/" \
        -e "s/^PHPMYADMIN_PORT=.*/PHPMYADMIN_PORT=$(( 8080 + offset ))/" \
        -e "s/^WORKSPACE_SSH_PORT=.*/WORKSPACE_SSH_PORT=$(( 2222 + offset ))/" \
        "$instance_dir/.env"
    rm -f "$instance_dir/.env.bak"

    # Copy default index.php
    ensure_instance_files

    echo -e "${GREEN}✅ Instance '$INSTANCE' created!${NC}"
    echo -e "   Config: $instance_dir/.env"
    echo -e "   Webroot: $instance_dir/www/"
    echo -e "   Runtime config: $instance_dir/config/"
    echo -e "   DB seed state: $instance_dir/seed-state/"
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
    echo -e "${CYAN}🐳 Starting instance '${BOLD}$INSTANCE${NC}${CYAN}'...${NC}"
    compose_cmd up -d --build "$@"
    import_mysql_seed_if_configured
    echo ""
    echo -e "${GREEN}✅ Instance '$INSTANCE' is running!${NC}"
    echo -e "   Shell:      ./scripts/ocompose.sh $INSTANCE shell"
    [[ "${PHP_ENABLED:-false}" == "true" ]]        && echo -e "   App:        http://localhost:${APP_PORT:-8000}"
    [[ "${MYSQL_ENABLED:-false}" == "true" ]]      && echo -e "   MySQL:      localhost:${MYSQL_PORT:-3306}"
    [[ "${PHPMYADMIN_ENABLED:-false}" == "true" ]]  && echo -e "   phpMyAdmin: http://localhost:${PHPMYADMIN_PORT:-8080}"
}

cmd_down() {
    require_instance
    load_instance_env
    echo -e "${CYAN}🛑 Stopping instance '$INSTANCE'...${NC}"
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
    # container to remove them so that non-root users can destroy instances.
    docker run --rm -v "$INSTANCES_DIR/$INSTANCE:/target" alpine rm -rf /target 2>/dev/null \
        || rm -rf "$INSTANCES_DIR/$INSTANCE"
    # If the bind-mount trick only emptied the dir, clean up the leftover.
    rm -rf "$INSTANCES_DIR/$INSTANCE" 2>/dev/null || true
    echo -e "${GREEN}✅ Instance '$INSTANCE' destroyed.${NC}"
}

cmd_list() {
    echo -e "${CYAN}📦 ocompose instances:${NC}"
    echo ""
    if [[ ! -d "$INSTANCES_DIR" ]] || [[ -z "$(ls -A "$INSTANCES_DIR" 2>/dev/null)" ]]; then
        echo -e "   ${YELLOW}(none)${NC}"
        echo "   Create one with: ocompose.sh <name> init"
        return
    fi

    printf "   ${BOLD}%-20s %-12s %-10s %-10s %-10s %-10s${NC}\n" "INSTANCE" "STATUS" "APP" "MYSQL" "PMA" "SSH"
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

        local app_port="-" mysql_port="-" pma_port="-" ssh_port="-"
        if [[ -f "$env_file" ]]; then
            app_port=$(grep "^APP_PORT=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "-")
            mysql_port=$(grep "^MYSQL_PORT=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "-")
            pma_port=$(grep "^PHPMYADMIN_PORT=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "-")
            ssh_port=$(grep "^WORKSPACE_SSH_PORT=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "-")

            if [[ "$app_port" == "-" ]]; then
                app_port="8000"
            fi
        fi

        printf "   %-20s %-22b %-10s %-10s %-10s %-10s\n" "$name" "$status" "$app_port" "$mysql_port" "$pma_port" "$ssh_port"
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
    status)  cmd_status ;;
    logs)    cmd_logs "$@" ;;
    destroy) cmd_destroy "$@" ;;
    help|*)  cmd_help ;;
esac