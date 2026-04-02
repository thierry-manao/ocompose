#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTANCES_DIR="$PROJECT_DIR/instances"

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

ensure_instance_files() {
    local instance_dir="$INSTANCES_DIR/$INSTANCE"

    mkdir -p "$instance_dir/www"
    mkdir -p "$instance_dir/config/nginx" "$instance_dir/config/php" "$instance_dir/config/mysql"

    copy_if_missing "$PROJECT_DIR/www/index.php" "$instance_dir/www/index.php"
    copy_if_missing "$PROJECT_DIR/config/nginx/default.conf" "$instance_dir/config/nginx/default.conf"
    copy_if_missing "$PROJECT_DIR/config/php/php.ini" "$instance_dir/config/php/php.ini"
    copy_if_missing "$PROJECT_DIR/config/mysql/my.cnf" "$instance_dir/config/mysql/my.cnf"
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

    if [[ -d "$instance_dir" ]]; then
        echo -e "${YELLOW}⚠  Instance '$INSTANCE' already exists at $instance_dir${NC}"
        read -p "   Overwrite .env? (y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0
    fi

    mkdir -p "$instance_dir/www"
    mkdir -p "$instance_dir/config/nginx" "$instance_dir/config/php" "$instance_dir/config/mysql"

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
    echo ""
    echo -e "   ${CYAN}Edit the .env file, then run:${NC}"
    echo -e "   ./scripts/ocompose.sh $INSTANCE up"
}

cmd_up() {
    require_instance
    load_instance_env
    echo -e "${CYAN}🐳 Starting instance '${BOLD}$INSTANCE${NC}${CYAN}'...${NC}"
    compose_cmd up -d --build "$@"
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
    load_instance_env
    echo -e "${RED}⚠  This will destroy instance '$INSTANCE' (containers, volumes, config).${NC}"
    read -p "   Are you sure? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

    compose_cmd down -v 2>/dev/null || true
    rm -rf "$INSTANCES_DIR/$INSTANCE"
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
    echo "  help       Show this help"
    echo ""
    echo "Examples:"
    echo "  ocompose.sh client-a init       # Create instance"
    echo "  ocompose.sh client-a up         # Start it"
    echo "  ocompose.sh client-a shell      # SSH into workspace"
    echo "  ocompose.sh blog init           # Create another instance"
    echo "  ocompose.sh list                # See all instances"
    echo ""
}

# ════════════════════════════════════════════
# Main
# ════════════════════════════════════════════

# Handle global commands (no instance needed)
case "${1:-help}" in
    list) cmd_list; exit 0 ;;
    help) cmd_help; exit 0 ;;
esac

# Instance-specific commands
INSTANCE="${1:-}"
COMMAND="${2:-help}"
shift 2 2>/dev/null || true

case "$COMMAND" in
    init)    cmd_init ;;
    up)      cmd_up "$@" ;;
    down)    cmd_down "$@" ;;
    restart) cmd_restart ;;
    shell)   cmd_shell ;;
    status)  cmd_status ;;
    logs)    cmd_logs "$@" ;;
    destroy) cmd_destroy ;;
    help|*)  cmd_help ;;
esac