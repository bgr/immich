#!/usr/bin/env bash
# deploy.sh — Build and deploy our Immich fork to Unraid machines.
#
# This builds a custom ImageGenius-compatible Docker image with our code
# and deploys it via Docker Compose Manager on Unraid.
#
# Usage:
#   ./deploy.sh init <name>            First-time setup for a host (creates .env.<name>)
#   ./deploy.sh build                  Build the Docker image (once)
#   ./deploy.sh push <name>            Transfer image and restart on a specific host
#   ./deploy.sh push                   Transfer image and restart on all configured hosts
#   Add --yes to skip all confirmations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IG_DOCKER_DIR="$SCRIPT_DIR/imagegenius-docker"
BUILD_DIR="$SCRIPT_DIR/.build"

IMAGE_NAME="immich-fork"
CONTAINER_NAME="immich-fork"
COMPOSE_PROJECT="immich-fork"

AUTO_YES=false
COMMAND=""
TARGET=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
    -*) echo "Unknown flag: $arg"; exit 1 ;;
    *)
      if [[ -z "$COMMAND" ]]; then
        COMMAND="$arg"
      elif [[ -z "$TARGET" ]]; then
        TARGET="$arg"
      else
        echo "Unexpected argument: $arg"; exit 1
      fi
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Ask user to confirm. Returns 0 if confirmed, 1 if declined.
# With --yes flag, always returns 0.
confirm() {
  if $AUTO_YES; then
    echo "  [auto-confirmed]"
    return 0
  fi
  read -rp "  Proceed? [Y/n] " answer
  [[ ! "$answer" =~ ^[Nn]$ ]]
}

# Print a step header
step() {
  echo ""
  echo "─── Step $1: $2 ───"
  echo ""
}

# Print info/status lines
info()    { echo "  $1"; }
ok()      { echo "  OK: $1"; }
err()     { echo "  ERROR: $1" >&2; }

# Return the .env file path for a given host name
env_file_for() {
  echo "$SCRIPT_DIR/.env.$1"
}

# Source the .env file for a given host name, or exit if it doesn't exist
load_env() {
  local name="$1"
  local env_file
  env_file=$(env_file_for "$name")
  if [[ ! -f "$env_file" ]]; then
    err "No config found for '$name' (expected $env_file)"
    err "Run './deploy.sh init $name' first."
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

# List all configured host names (derived from .env.* files)
list_hosts() {
  local hosts=()
  for f in "$SCRIPT_DIR"/.env.*; do
    [[ -f "$f" ]] || continue
    local name="${f##*/.env.}"
    hosts+=("$name")
  done
  echo "${hosts[@]}"
}

# Extract an env var value from a docker inspect JSON array of "KEY=VALUE" strings.
# Usage: parse_docker_env "$json_array" "VAR_NAME"
parse_docker_env() {
  echo "$1" | tr ',' '\n' | tr -d '[]"' | grep "^$2=" | head -1 | cut -d= -f2-
}

# Extract a bind mount source path from docker inspect JSON.
# Usage: parse_docker_mount "$json_array" "/container/path"
parse_docker_mount() {
  python3 -c "
import json, sys
mounts = json.loads(sys.argv[1])
for m in mounts:
    if m.get('Destination') == sys.argv[2] and m.get('Type') == 'bind':
        print(m['Source'])
        break
" "$1" "$2" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------

# Verify that all required tools are installed on this machine.
# Everything else (Node, Python, pnpm, etc.) is installed inside the Docker
# container during the build — you don't need them locally.
check_prerequisites() {
  local missing=()

  command -v docker &>/dev/null  || missing+=("docker   — see Troubleshooting section in deploy-to-unraid/README.md")
  command -v ssh &>/dev/null     || missing+=("ssh      — apt install openssh-client")
  command -v scp &>/dev/null     || missing+=("scp      — apt install openssh-client")
  command -v git &>/dev/null     || missing+=("git      — apt install git")
  command -v python3 &>/dev/null || missing+=("python3  — apt install python3")
  command -v gzip &>/dev/null    || missing+=("gzip     — apt install gzip")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools. Install them and try again:"
    for tool in "${missing[@]}"; do
      echo "    $tool"
    done
    exit 1
  fi

  # Check Docker daemon is running
  if ! docker info &>/dev/null; then
    err "Docker is installed but the daemon is not running."
    err "See the Troubleshooting section in deploy-to-unraid/README.md"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Build the Docker image
# ---------------------------------------------------------------------------

do_build() {
  # Make sure the ImageGenius repo is cloned
  if [[ ! -d "$IG_DOCKER_DIR/.git" ]]; then
    err "ImageGenius repo not found at $IG_DOCKER_DIR"
    err "Run './deploy.sh init <name>' first, or clone it manually:"
    err "  git clone https://github.com/imagegenius/docker-immich.git $IG_DOCKER_DIR"
    exit 1
  fi

  info "Preparing build context..."

  # Clean and create the build directory
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"

  # Copy the ImageGenius Dockerfile and root/ (s6-overlay scripts)
  cp "$IG_DOCKER_DIR/Dockerfile" "$BUILD_DIR/Dockerfile"
  cp -r "$IG_DOCKER_DIR/root" "$BUILD_DIR/root"

  # Copy our immich source into the build context.
  # This is the code that will be compiled inside the container.
  # We use tar to exclude node_modules, .git, and other build artifacts
  # that would bloat the context and aren't needed (pnpm install runs inside the container).
  info "Copying source tree into build context..."
  mkdir -p "$BUILD_DIR/immich-source"
  tar cf - \
    --exclude='node_modules' \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='.venv' \
    -C "$REPO_ROOT" \
    server web open-api cli i18n machine-learning plugins \
    package.json pnpm-lock.yaml pnpm-workspace.yaml .pnpmfile.cjs \
    | tar xf - -C "$BUILD_DIR/immich-source"
  # Patch the Dockerfile:
  #   1. Add "COPY immich-source/ /tmp/immich/" before the RUN command
  #   2. Remove the block that downloads the source tarball from GitHub
  # See patch-dockerfile.py for details on what exactly is changed.
  info "Patching Dockerfile to use local source..."
  python3 "$SCRIPT_DIR/patch-dockerfile.py" "$BUILD_DIR/Dockerfile"

  info "Building Docker image: $IMAGE_NAME:latest"
  info "(This runs 'docker build' which compiles everything inside the container."
  info " It takes a while on the first run but Docker caches layers for subsequent builds.)"
  echo ""
  confirm || exit 1

  docker build -t "$IMAGE_NAME:latest" "$BUILD_DIR"

  echo ""
  ok "Image built: $IMAGE_NAME:latest"
}

# ---------------------------------------------------------------------------
# Transfer the image to a host
# ---------------------------------------------------------------------------

do_transfer() {
  local tar_file="$BUILD_DIR/$IMAGE_NAME.tar.gz"

  # Save the image to a compressed archive once (reuse across hosts)
  if [[ ! -f "$tar_file" ]]; then
    info "Saving Docker image to compressed archive..."
    docker save "$IMAGE_NAME:latest" | gzip > "$tar_file"
  fi
  local size
  size=$(du -h "$tar_file" | cut -f1)
  info "Archive size: $size"

  info "Transferring to $UNRAID_HOST (this may take a few minutes)..."
  echo ""
  confirm || exit 1

  scp "$tar_file" "$UNRAID_HOST:/tmp/$IMAGE_NAME.tar.gz"
  info "Loading image on $UNRAID_HOST..."
  ssh "$UNRAID_HOST" "docker load -i /tmp/$IMAGE_NAME.tar.gz && rm /tmp/$IMAGE_NAME.tar.gz"

  ok "Image loaded on $UNRAID_HOST."
}

# ---------------------------------------------------------------------------
# Backup the database
# ---------------------------------------------------------------------------

do_backup() {
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local remote_path="$IMMICH_CONFIG_PATH/immich-backup-$timestamp.sql"

  info "Will create a backup dump of the Immich database on $UNRAID_HOST."
  info "Command: docker exec $DB_HOSTNAME pg_dump -U $DB_USERNAME -d $DB_DATABASE_NAME"
  info "Output:  $remote_path"
  echo ""
  confirm || { info "Skipping backup."; return 0; }

  ssh "$UNRAID_HOST" "docker exec $DB_HOSTNAME pg_dump -U $DB_USERNAME -d $DB_DATABASE_NAME > $remote_path"

  local backup_size
  backup_size=$(ssh "$UNRAID_HOST" "du -h '$remote_path' | cut -f1")
  ok "Backup saved: $remote_path ($backup_size)"

  # Verify the backup contains Immich-specific content, not just any SQL dump.
  # pg_dump uses singular table names (public.asset, public.partner, public."user")
  # and COPY statements like: COPY public.asset (...) FROM stdin;
  info "Verifying backup contents..."
  local checks_passed=0
  local checks_total=4

  # 1. Contains the asset table (core Immich table — rules out a wrong database)
  if ssh "$UNRAID_HOST" "grep -q 'CREATE TABLE public.asset' '$remote_path'"; then
    ok "Found 'asset' table definition."
    checks_passed=$((checks_passed + 1))
  else
    err "Missing 'asset' table — this may not be an Immich database."
  fi

  # 2. Contains the partner table (the table our migration modifies)
  if ssh "$UNRAID_HOST" "grep -q 'CREATE TABLE public.partner' '$remote_path'"; then
    ok "Found 'partner' table definition."
    checks_passed=$((checks_passed + 1))
  else
    err "Missing 'partner' table."
  fi

  # 3. Contains user data (not an empty DB)
  if ssh "$UNRAID_HOST" "grep -q 'COPY public.\"user\"' '$remote_path'"; then
    ok "Found user data."
    checks_passed=$((checks_passed + 1))
  else
    err "No user data found — the database may be empty."
  fi

  # 4. Contains recent timestamps (within this year) — confirms it's live data
  local current_year
  current_year=$(date +%Y)
  if ssh "$UNRAID_HOST" "grep -q '$current_year-' '$remote_path'"; then
    ok "Found timestamps from $current_year."
    checks_passed=$((checks_passed + 1))
  else
    err "No timestamps from $current_year — this may be stale data."
  fi

  echo ""
  if [[ "$checks_passed" -eq "$checks_total" ]]; then
    ok "All $checks_total checks passed — backup looks valid."
  else
    err "Only $checks_passed/$checks_total checks passed."
    info "Review the backup manually before continuing."
    confirm || { err "Aborting."; exit 1; }
  fi
}

# ---------------------------------------------------------------------------
# Create Docker Compose Manager project on Unraid
# ---------------------------------------------------------------------------

do_create_compose_project() {
  local project_dir="$COMPOSE_MANAGER_PROJECTS_DIR/$COMPOSE_PROJECT"

  info "Will create Docker Compose Manager project at:"
  info "  $UNRAID_HOST:$project_dir"

  # Build the docker-compose.yml content
  local compose_yml
  compose_yml="services:
  immich:
    image: ${IMAGE_NAME}:latest
    container_name: ${CONTAINER_NAME}
    environment:
      - TZ=${TZ}
      - DB_HOSTNAME=${DB_HOSTNAME}
      - DB_USERNAME=${DB_USERNAME}
      - DB_PASSWORD=${DB_PASSWORD}
      - DB_PORT=${DB_PORT}
      - DB_DATABASE_NAME=${DB_DATABASE_NAME}
      - REDIS_HOSTNAME=${REDIS_HOSTNAME}
      - REDIS_PASSWORD=${REDIS_PASSWORD}
      - REDIS_PORT=${REDIS_PORT}
      - PUID=${PUID}
      - PGID=${PGID}
      - MACHINE_LEARNING_WORKERS=${MACHINE_LEARNING_WORKERS}
      - MACHINE_LEARNING_WORKER_TIMEOUT=${MACHINE_LEARNING_WORKER_TIMEOUT}
    volumes:
      - ${IMMICH_CONFIG_PATH}:/config
      - ${IMMICH_PHOTOS_PATH}:/photos
      - ${IMMICH_THUMBS_PATH}:/photos/thumbs
      - ${IMMICH_IMPORT_PATH}:/import
    ports:
      - \"${HOST_PORT}:8080\"
    networks:
      - ${DOCKER_NETWORK}
    restart: unless-stopped

networks:
  ${DOCKER_NETWORK}:
    external: true"

  local override_yml
  override_yml="services:
  immich:
    labels:
      net.unraid.docker.managed: composeman
      net.unraid.docker.icon: \"https://immich.app/img/immich-logo.svg\"
      net.unraid.docker.webui: \"http://[IP]:${HOST_PORT}/\"
      net.unraid.docker.shell: bash"

  info ""
  info "docker-compose.yml:"
  echo "$compose_yml" | sed 's/^/    /'
  info ""
  info "docker-compose.override.yml:"
  echo "$override_yml" | sed 's/^/    /'
  echo ""

  confirm || exit 1

  # Create the project directory and files on Unraid
  ssh "$UNRAID_HOST" "mkdir -p '$project_dir'"
  echo "$compose_yml" | ssh "$UNRAID_HOST" "cat > '$project_dir/docker-compose.yml'"
  echo "$override_yml" | ssh "$UNRAID_HOST" "cat > '$project_dir/docker-compose.override.yml'"

  # Create compose manager metadata files
  ssh "$UNRAID_HOST" "echo '$COMPOSE_PROJECT' > '$project_dir/name'"
  ssh "$UNRAID_HOST" "echo 'true' > '$project_dir/autostart'"
  ssh "$UNRAID_HOST" "echo 'Immich fork with partner sharing improvements' > '$project_dir/description'"

  ok "Compose project created."
}

# ---------------------------------------------------------------------------
# Container management
# ---------------------------------------------------------------------------

do_stop_old_container() {
  # Find the running ImageGenius container
  local old_container
  old_container=$(ssh "$UNRAID_HOST" \
    "docker ps --filter 'ancestor=ghcr.io/imagegenius/immich' --format '{{.Names}}' | head -1" \
    2>/dev/null || true)

  if [[ -z "$old_container" ]]; then
    info "No running ImageGenius container found (may already be stopped)."
    return 0
  fi

  info "Found old container: $old_container"
  info "Will stop it (not delete — you can restart it to rollback)."
  info "Command: docker stop $old_container"
  echo ""
  confirm || exit 1

  ssh "$UNRAID_HOST" "docker stop '$old_container'"
  ok "Old container stopped."
}

do_start_or_restart_container() {
  local project_dir="$COMPOSE_MANAGER_PROJECTS_DIR/$COMPOSE_PROJECT"

  info "Starting the Immich container (recreates if already running)..."
  info "Command: cd $project_dir && docker compose up -d --force-recreate"
  echo ""
  confirm || exit 1

  ssh "$UNRAID_HOST" "cd '$project_dir' && docker compose up -d --force-recreate"

  do_verify
}

do_verify() {
  info "Waiting 10 seconds for the container to initialize..."
  sleep 10

  local status
  status=$(ssh "$UNRAID_HOST" \
    "docker inspect '$CONTAINER_NAME' --format '{{.State.Status}}'" 2>/dev/null || echo "not found")

  if [[ "$status" == "running" ]]; then
    ok "Container is running."
    info ""
    info "Web UI: http://$UNRAID_HOST:$HOST_PORT"
    info "Logs:   ssh $UNRAID_HOST docker logs -f $CONTAINER_NAME"
  else
    err "Container status: $status"
    err "Check logs: ssh $UNRAID_HOST docker logs $CONTAINER_NAME"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Command: init <name>
# ---------------------------------------------------------------------------

cmd_init() {
  local name="$TARGET"
  if [[ -z "$name" ]]; then
    err "Usage: $0 init <name>"
    err "Example: $0 init dumpy"
    exit 1
  fi

  local env_file
  env_file=$(env_file_for "$name")

  check_prerequisites

  echo ""
  echo "=== First-time setup for '$name' ==="
  echo ""
  echo "This will:"
  echo "  1. Read config from your existing ImageGenius Immich container"
  echo "  2. Generate $env_file for future deploys"
  echo "  3. Clone the ImageGenius docker repo (for s6-overlay scripts)"
  echo "  4. Back up the database"
  echo "  5. Set up a Docker Compose Manager project"
  echo "  6. Stop the old container"
  echo ""

  # --- Get Unraid hostname ---

  if $AUTO_YES; then
    err "Cannot run init with --yes (needs interactive input)."
    exit 1
  fi

  read -rp "  Enter Unraid SSH hostname (press enter for '$name'): " UNRAID_HOST
  if [[ -z "$UNRAID_HOST" ]]; then
    UNRAID_HOST="$name"
  fi

  info "Testing SSH connection to $UNRAID_HOST..."
  if ! ssh "$UNRAID_HOST" "echo ok" &>/dev/null; then
    err "Cannot SSH to $UNRAID_HOST. Set up SSH key auth first."
    exit 1
  fi
  ok "SSH works."

  # --- Step 1: Discover config from existing container ---

  step 1 "Discover config from existing Immich container"

  info "Looking for a running ImageGenius Immich container on $UNRAID_HOST..."

  local ig_container
  ig_container=$(ssh "$UNRAID_HOST" \
    "docker ps --filter 'ancestor=ghcr.io/imagegenius/immich' --format '{{.Names}}' | head -1" \
    2>/dev/null || true)
  if [[ -z "$ig_container" ]]; then
    # Try by name as fallback
    ig_container=$(ssh "$UNRAID_HOST" \
      "docker ps --format '{{.Names}}' | grep -i immich | grep -v postgres | head -1" \
      2>/dev/null || true)
  fi
  if [[ -z "$ig_container" ]]; then
    err "Cannot find a running Immich container on $UNRAID_HOST."
    exit 1
  fi
  ok "Found container: $ig_container"

  info "Reading environment variables..."
  local env_json
  env_json=$(ssh "$UNRAID_HOST" "docker inspect '$ig_container' --format '{{json .Config.Env}}'")

  local db_hostname db_username db_password db_port db_database_name
  local redis_hostname redis_password redis_port
  local puid pgid tz ml_workers ml_worker_timeout

  db_hostname=$(parse_docker_env "$env_json" "DB_HOSTNAME")
  db_username=$(parse_docker_env "$env_json" "DB_USERNAME")
  db_password=$(parse_docker_env "$env_json" "DB_PASSWORD")
  db_port=$(parse_docker_env "$env_json" "DB_PORT")
  db_database_name=$(parse_docker_env "$env_json" "DB_DATABASE_NAME")
  redis_hostname=$(parse_docker_env "$env_json" "REDIS_HOSTNAME")
  redis_password=$(parse_docker_env "$env_json" "REDIS_PASSWORD")
  redis_port=$(parse_docker_env "$env_json" "REDIS_PORT")
  puid=$(parse_docker_env "$env_json" "PUID")
  pgid=$(parse_docker_env "$env_json" "PGID")
  tz=$(parse_docker_env "$env_json" "TZ")
  ml_workers=$(parse_docker_env "$env_json" "MACHINE_LEARNING_WORKERS")
  ml_worker_timeout=$(parse_docker_env "$env_json" "MACHINE_LEARNING_WORKER_TIMEOUT")

  info "Reading volume mounts..."
  local mounts_json
  mounts_json=$(ssh "$UNRAID_HOST" "docker inspect '$ig_container' --format '{{json .Mounts}}'")

  local config_path photos_path thumbs_path import_path
  config_path=$(parse_docker_mount "$mounts_json" "/config")
  photos_path=$(parse_docker_mount "$mounts_json" "/photos")
  thumbs_path=$(parse_docker_mount "$mounts_json" "/photos/thumbs")
  import_path=$(parse_docker_mount "$mounts_json" "/import")

  info "Reading Docker network..."
  local network_name
  network_name=$(ssh "$UNRAID_HOST" \
    "docker inspect '$ig_container' --format '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}}{{end}}'")

  info "Reading port mapping..."
  local host_port
  host_port=$(ssh "$UNRAID_HOST" \
    "docker port '$ig_container' 8080/tcp 2>/dev/null | head -1 | rev | cut -d: -f1 | rev" \
    || echo "8080")

  ok "Config discovered."

  # --- Step 2: Generate .env ---

  step 2 "Generate .env.$name"

  cat > "$env_file" << EOF
# Generated by deploy.sh init $name on $(date -Iseconds)
# Edit this file if any values need updating.

# Unraid connection
UNRAID_HOST="$UNRAID_HOST"

# Database
DB_HOSTNAME="${db_hostname}"
DB_USERNAME="${db_username}"
DB_PASSWORD="${db_password}"
DB_PORT="${db_port:-5432}"
DB_DATABASE_NAME="${db_database_name:-immich}"

# Redis
REDIS_HOSTNAME="${redis_hostname}"
REDIS_PASSWORD="${redis_password}"
REDIS_PORT="${redis_port:-6379}"

# Container settings
PUID="${puid:-99}"
PGID="${pgid:-100}"
TZ="${tz:-Etc/UTC}"
MACHINE_LEARNING_WORKERS="${ml_workers:-1}"
MACHINE_LEARNING_WORKER_TIMEOUT="${ml_worker_timeout:-120}"

# Volume paths on Unraid
IMMICH_CONFIG_PATH="${config_path:-/mnt/user/appdata/immich}"
IMMICH_PHOTOS_PATH="${photos_path:-/mnt/user/ImmichLibrary}"
IMMICH_THUMBS_PATH="${thumbs_path:-/mnt/user/ImmichThumbnails}"
IMMICH_IMPORT_PATH="${import_path:-/mnt/user/ImmichImport}"

# Docker settings
DOCKER_NETWORK="${network_name:-bridge}"
HOST_PORT="${host_port:-8080}"

# Image and container naming
IMAGE_NAME="$IMAGE_NAME"
CONTAINER_NAME="$CONTAINER_NAME"
COMPOSE_PROJECT="$COMPOSE_PROJECT"

# Docker Compose Manager
COMPOSE_MANAGER_PROJECTS_DIR="/mnt/user/appdata/docker-compose-manager/projects"
EOF

  info "Generated .env.$name:"
  echo ""
  cat "$env_file" | sed 's/^/    /'
  echo ""
  info "Review the values above. You can edit $env_file later if needed."
  confirm || exit 1
  ok ".env.$name saved."

  # Load it for subsequent steps
  load_env "$name"

  # --- Step 3: Clone ImageGenius docker repo ---

  step 3 "Clone ImageGenius docker-immich repository"

  info "We need the ImageGenius repo for the s6-overlay service scripts"
  info "(the init scripts and process supervisors that run inside the container)."

  if [[ -d "$IG_DOCKER_DIR/.git" ]]; then
    info "Already cloned at $IG_DOCKER_DIR — pulling latest..."
    git -C "$IG_DOCKER_DIR" pull --quiet
  else
    info "Will clone: https://github.com/imagegenius/docker-immich.git"
    info "       Into: $IG_DOCKER_DIR"
    echo ""
    confirm || exit 1
    git clone --quiet https://github.com/imagegenius/docker-immich.git "$IG_DOCKER_DIR"
  fi
  ok "ImageGenius repo ready."

  # --- Step 4: Backup database ---

  step 4 "Back up the database"
  do_backup

  # --- Step 5: Create Docker Compose project ---

  step 5 "Create Docker Compose Manager project on Unraid"
  do_create_compose_project

  # --- Step 6: Stop old container ---

  step 6 "Stop old container"
  do_stop_old_container

  echo ""
  echo "=== First-time setup for '$name' complete ==="
  echo ""
  info "IMPORTANT: Go to the Unraid web UI → Docker tab and disable auto-start"
  info "for the original 'immich' container, so it doesn't come back after a reboot."
  info "The new fork container auto-starts via Docker Compose Manager."
  info ""
  info "Now run './deploy.sh build' to build the image,"
  info "then './deploy.sh push $name' to transfer and start it."
}

# ---------------------------------------------------------------------------
# Command: build
# ---------------------------------------------------------------------------

cmd_build() {
  check_prerequisites

  echo ""
  echo "=== Build Immich fork Docker image ==="
  echo ""

  do_build
}

# ---------------------------------------------------------------------------
# Command: push <name> | push (all)
# ---------------------------------------------------------------------------

do_push_one() {
  local name="$1"
  load_env "$name"

  echo ""
  echo "--- Pushing to $name ($UNRAID_HOST) ---"
  echo ""

  # Verify the image exists
  if ! docker image inspect "$IMAGE_NAME:latest" &>/dev/null; then
    err "Image $IMAGE_NAME:latest not found. Run './deploy.sh build' first."
    exit 1
  fi

  do_transfer
  do_start_or_restart_container

  echo ""
  ok "$name ($UNRAID_HOST) updated."
  info "Web UI: http://$UNRAID_HOST:$HOST_PORT"
}

cmd_push() {
  check_prerequisites

  if [[ -n "$TARGET" ]]; then
    # Push to a specific host
    echo ""
    echo "=== Push to $TARGET ==="
    do_push_one "$TARGET"
  else
    # Push to all configured hosts
    local hosts
    hosts=$(list_hosts)
    if [[ -z "$hosts" ]]; then
      err "No configured hosts found (no .env.* files in $SCRIPT_DIR)."
      err "Run './deploy.sh init <name>' first."
      exit 1
    fi

    echo ""
    echo "=== Push to all hosts: $hosts ==="

    local failed=()
    for name in $hosts; do
      if ! do_push_one "$name"; then
        failed+=("$name")
        err "Failed to push to $name, continuing with remaining hosts..."
      fi
    done

    echo ""
    if [[ ${#failed[@]} -gt 0 ]]; then
      err "Failed hosts: ${failed[*]}"
      exit 1
    else
      echo "=== All hosts updated ==="
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${COMMAND:-}" in
  init)
    cmd_init
    ;;
  build)
    cmd_build
    ;;
  push)
    cmd_push
    ;;
  *)
    echo "Usage: $0 <command> [<name>] [--yes]"
    echo ""
    echo "Commands:"
    echo "  init <name>    First-time setup for a host (creates .env.<name>)"
    echo "  build          Build the Docker image locally"
    echo "  push <name>    Transfer image and restart on a specific host"
    echo "  push           Transfer image and restart on all configured hosts"
    echo ""
    echo "Flags:"
    echo "  --yes, -y      Skip all confirmations"
    echo ""
    hosts=$(list_hosts 2>/dev/null || true)
    if [[ -n "$hosts" ]]; then
      echo "Configured hosts: $hosts"
    else
      echo "No hosts configured yet. Run '$0 init <name>' to get started."
    fi
    exit 1
    ;;
esac
