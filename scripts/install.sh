#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

trap 'status=$?; if [[ $status -ne 0 ]]; then echo "Installer stopped unexpectedly (exit $status)." >&2; fi' EXIT

if [[ ! -t 0 ]]; then
  echo "This installer is interactive and requires a terminal." >&2
  exit 1
fi

prompt() {
  local label="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
  else
    read -r -p "$label: " value
  fi
  printf '%s' "${value:-$default}"
}

prompt_required() {
  local label="$1"
  local value
  while true; do
    read -r -p "$label: " value
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return
    fi
  done
}

prompt_secret() {
  local label="$1"
  local default="${2:-}"
  local value
  read -r -s -p "$label: " value
  echo >&2
  printf '%s' "${value:-$default}"
}

confirm() {
  local label="$1"
  local default="${2:-y}"
  local suffix="[Y/n]"
  [[ "$default" == "n" ]] && suffix="[y/N]"
  local value
  read -r -p "$label $suffix: " value
  value="${value:-$default}"
  [[ "${value,,}" == "y" || "${value,,}" == "yes" ]]
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))'
  fi
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))'
  fi
}

declare -A ENV

echo "Payload installer"
echo

echo "How should PostgreSQL and Redis be provisioned?"
echo "  1) Docker containers inside the current VM"
echo "  2) Separate Proxmox containers (LXC)"
echo "  3) Existing external PostgreSQL and Redis servers"
DB_MODE="$(prompt "Choice" "1")"

case "$DB_MODE" in
  1)
    ENV[POSTGRES_USER]="$(prompt "PostgreSQL username" "payload")"
    ENV[POSTGRES_DB]="$(prompt "PostgreSQL database name" "payload_dev")"
    ENV[POSTGRES_PASSWORD]="$(prompt_secret "PostgreSQL password" "$(random_secret)")"
    ENV[REDIS_PASSWORD]="$(prompt_secret "Redis password" "$(random_secret)")"
    ENV[DATABASE_URL]="postgres://$([[ ${ENV[POSTGRES_USER]} == *:* ]] && printf '%%s' 'payload' || printf '%s' "${ENV[POSTGRES_USER]}"):$(printf '%s' "${ENV[POSTGRES_PASSWORD]}" | sed 's/%/%25/g;s/@/%40/g;s/:/%3A/g;s/#/%23/g;s/[/]/%2F/g')@localhost:5432/${ENV[POSTGRES_DB]}"
    ENV[REDIS_URL]="redis://:${ENV[REDIS_PASSWORD]}@localhost:6379"
    ;;
  2)
    echo "Proxmox access credentials"
    ENV[PROXMOX_HOST]="$(prompt_required "Proxmox host (IP or hostname)")"
    ENV[PROXMOX_PORT]="$(prompt "PROXMOX_PORT" "8006")"
    while true; do
      ENV[PROXMOX_TOKEN_ID]="$(prompt_required "Proxmox full API token ID (for example payload@pve!payload)")"
      if [[ "${ENV[PROXMOX_TOKEN_ID]}" =~ ^[^@[:space:]]+@[^![:space:]]+![^[:space:]]+$ ]]; then
        break
      fi
      echo "Invalid token ID. Use the full format user@realm!token-name." >&2
    done
    while true; do
      ENV[PROXMOX_TOKEN_SECRET]="$(prompt_secret "Proxmox API token secret")"
      if [[ -n "${ENV[PROXMOX_TOKEN_SECRET]}" ]]; then
        break
      fi
      echo "Proxmox API token secret cannot be blank." >&2
    done
    ENV[PROXMOX_DEFAULT_NODE]="$(prompt_required "Proxmox default node")"
    ENV[PROXMOX_VERIFY_TLS]="$(prompt "PROXMOX_VERIFY_TLS" "true")"
    ENV[VM_NAME_PREFIX]="$(prompt "VM_NAME_PREFIX" "payload")"

    PVE_ACCESS_MODE="2"
    if command -v pct >/dev/null 2>&1 && command -v pveversion >/dev/null 2>&1; then
      PVE_ACCESS_MODE="1"
    fi
    PVE_ACCESS_MODE="$(prompt "Proxmox access method (1=local pct, 2=SSH)" "$PVE_ACCESS_MODE")"

    case "$PVE_ACCESS_MODE" in
      1)
        if ! command -v pct >/dev/null 2>&1 || ! command -v pveversion >/dev/null 2>&1; then
          echo "Local pct mode requires this installer to run on the Proxmox host." >&2
          exit 1
        fi
        ENV[PROXMOX_SSH_HOST]=""
        ENV[PROXMOX_SSH_USER]=""
        ENV[PROXMOX_SSH_KEY_PATH]=""
        ENV[PROXMOX_SSH_PASSWORD]=""
        ENV[PROXMOX_SSH_PORT]="22"
        ;;
      2)
        ENV[PROXMOX_SSH_HOST]="$(prompt "PROXMOX_SSH_HOST" "${ENV[PROXMOX_HOST]}")"
        ENV[PROXMOX_SSH_USER]="$(prompt "PROXMOX_SSH_USER" "root")"
        ENV[PROXMOX_SSH_PORT]="$(prompt "PROXMOX_SSH_PORT" "22")"
        SSH_AUTH_METHOD="$(prompt "SSH authentication (1=private key, 2=password)" "1")"
        case "$SSH_AUTH_METHOD" in
          1)
            ENV[PROXMOX_SSH_KEY_PATH]="$(prompt_required "Path to SSH private key")"
            ENV[PROXMOX_SSH_PASSWORD]=""
            ;;
          2)
            ENV[PROXMOX_SSH_KEY_PATH]=""
            ENV[PROXMOX_SSH_PASSWORD]="$(prompt_secret "PROXMOX_SSH_PASSWORD")"
            if [[ -z "${ENV[PROXMOX_SSH_PASSWORD]}" ]]; then
              echo "Proxmox SSH password cannot be blank." >&2
              exit 1
            fi
            if ! command -v sshpass >/dev/null 2>&1; then
              echo "sshpass is required for password authentication. Install it with: apt-get install -y sshpass" >&2
              exit 1
            fi
            ;;
          *)
            echo "Invalid SSH authentication method." >&2
            exit 1
            ;;
        esac
        ;;
      *)
        echo "Invalid Proxmox access method." >&2
        exit 1
        ;;
    esac

    pve_exec() {
      if [[ "$PVE_ACCESS_MODE" == "1" ]]; then
        "$@"
        return
      fi
      local ssh_args=(-p "${ENV[PROXMOX_SSH_PORT]}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
      if [[ -n "${ENV[PROXMOX_SSH_KEY_PATH]}" ]]; then
        ssh_args+=(-i "${ENV[PROXMOX_SSH_KEY_PATH]}")
        ssh "${ssh_args[@]}" "${ENV[PROXMOX_SSH_USER]}@${ENV[PROXMOX_SSH_HOST]}" "$@"
      elif [[ -n "${ENV[PROXMOX_SSH_PASSWORD]}" ]]; then
        sshpass -p "${ENV[PROXMOX_SSH_PASSWORD]}" ssh -p "${ENV[PROXMOX_SSH_PORT]}" -o StrictHostKeyChecking=accept-new "${ENV[PROXMOX_SSH_USER]}@${ENV[PROXMOX_SSH_HOST]}" "$@"
      else
        echo "No Proxmox SSH authentication method is configured." >&2
        return 1
      fi
    }

    if ! pve_exec true >/dev/null 2>&1; then
      echo "Could not connect to ${ENV[PROXMOX_SSH_USER]}@${ENV[PROXMOX_SSH_HOST]} over SSH." >&2
      echo "Check PROXMOX_SSH_HOST, port, user, key path, or password." >&2
      exit 1
    fi

    ENV[POSTGRES_USER]="$(prompt "PostgreSQL username" "payload")"
    ENV[POSTGRES_DB]="$(prompt "PostgreSQL database name" "payload")"
    ENV[POSTGRES_PASSWORD]="$(prompt_secret "PostgreSQL password" "$(random_secret)")"
    ENV[REDIS_PASSWORD]="$(prompt_secret "Redis password" "$(random_secret)")"

    CT_TEMPLATE="$(prompt "Proxmox Debian CT template path" "/var/lib/vz/template/cache/debian-13-standard_13.0-1_amd64.tar.zst")"
    CT_STORAGE="$(prompt "Proxmox rootfs storage" "local-lvm")"
    CT_BRIDGE="$(prompt "Proxmox network bridge" "vmbr0")"
    PG_CT_ID="$(prompt "PostgreSQL CT ID" "201")"
    REDIS_CT_ID="$(prompt "Redis CT ID" "202")"
    PG_IP="$(prompt_required "PostgreSQL CT static IP/CIDR (for example 192.168.1.201/24)")"
    REDIS_IP="$(prompt_required "Redis CT static IP/CIDR (for example 192.168.1.202/24)")"
    CT_GATEWAY="$(prompt_required "Network gateway")"
    CT_ROOT_PASSWORD="$(prompt_secret "Temporary CT root password" "$(random_secret)")"

    if ! pve_exec test -f "$CT_TEMPLATE"; then
      echo "CT template not found on Proxmox: $CT_TEMPLATE" >&2
      echo "Download one with: pveam update && pveam available" >&2
      exit 1
    fi

    create_ct() {
      local id="$1"
      local hostname="$2"
      local ip="$3"
      pve_exec pct create "$id" "$CT_TEMPLATE" \
        --hostname "$hostname" \
        --cores 2 --memory 2048 --swap 512 \
        --rootfs "$CT_STORAGE:8" \
        --net0 "name=eth0,bridge=$CT_BRIDGE,ip=$ip,gw=$CT_GATEWAY" \
        --password "$CT_ROOT_PASSWORD" \
        --unprivileged 1 --features nesting=1 \
        --onboot 1
      pve_exec pct start "$id"
      for _ in {1..30}; do
        pve_exec pct exec "$id" -- true >/dev/null 2>&1 && return
        sleep 1
      done
      echo "CT $id did not start in time." >&2
      exit 1
    }

    echo "Creating PostgreSQL CT..."
    create_ct "$PG_CT_ID" "payload-postgres" "$PG_IP"
    pve_exec pct exec "$PG_CT_ID" -- bash -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib'

    local_pg_ip="${PG_IP%%/*}"
    pg_sql_password="${ENV[POSTGRES_PASSWORD]//\'/\'\'}"
    pve_exec pct exec "$PG_CT_ID" -- bash -c "runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE ${ENV[POSTGRES_USER]} WITH LOGIN PASSWORD '${pg_sql_password}' ;
CREATE DATABASE ${ENV[POSTGRES_DB]} OWNER ${ENV[POSTGRES_USER]};
SQL
"
    pve_exec pct exec "$PG_CT_ID" -- bash -c "sed -i \"s/^#*listen_addresses.*/listen_addresses = '\\''*'\\''/\" /etc/postgresql/*/main/postgresql.conf"
    pve_exec pct exec "$PG_CT_ID" -- bash -c "echo 'host all ${ENV[POSTGRES_USER]} 0.0.0.0/0 scram-sha-256' >> /etc/postgresql/*/main/pg_hba.conf"
    pve_exec pct exec "$PG_CT_ID" -- bash -c 'systemctl restart postgresql'

    echo "Creating Redis CT..."
    create_ct "$REDIS_CT_ID" "payload-redis" "$REDIS_IP"
    pve_exec pct exec "$REDIS_CT_ID" -- bash -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server'
    pve_exec pct exec "$REDIS_CT_ID" -- bash -c "sed -i 's/^bind .*/bind 0.0.0.0/' /etc/redis/redis.conf"
    pve_exec pct exec "$REDIS_CT_ID" -- bash -c "sed -i 's/^protected-mode .*/protected-mode no/' /etc/redis/redis.conf"
    pve_exec pct exec "$REDIS_CT_ID" -- bash -c "echo \"requirepass ${ENV[REDIS_PASSWORD]}\" >> /etc/redis/redis.conf"
    pve_exec pct exec "$REDIS_CT_ID" -- bash -c 'systemctl restart redis-server'

    db_password_url="$(printf '%s' "${ENV[POSTGRES_PASSWORD]}" | sed 's/%/%25/g;s/@/%40/g;s/:/%3A/g;s/#/%23/g;s/[/]/%2F/g')"
    ENV[DATABASE_URL]="postgres://${ENV[POSTGRES_USER]}:${db_password_url}@${local_pg_ip}:5432/${ENV[POSTGRES_DB]}"
    ENV[REDIS_URL]="redis://:${ENV[REDIS_PASSWORD]}@${REDIS_IP%%/*}:6379"
    ;;
  3)
    ENV[DATABASE_URL]="$(prompt_required "PostgreSQL DATABASE_URL")"
    ENV[REDIS_URL]="$(prompt_required "Redis REDIS_URL")"
    ;;
  *)
    echo "Invalid database/Redis setup choice." >&2
    exit 1
    ;;
esac

ENV[AUTH_SECRET]="$(prompt_secret "AUTH_SECRET" "$(random_secret)")"
if [[ "$DB_MODE" != "2" ]]; then
  ENV[PROXMOX_HOST]="$(prompt_required "Proxmox host (IP or hostname)")"
  ENV[PROXMOX_PORT]="$(prompt "PROXMOX_PORT" "8006")"
  while true; do
    ENV[PROXMOX_TOKEN_ID]="$(prompt_required "Proxmox full API token ID (for example payload@pve!payload)")"
    if [[ "${ENV[PROXMOX_TOKEN_ID]}" =~ ^[^@[:space:]]+@[^![:space:]]+![^[:space:]]+$ ]]; then
      break
    fi
    echo "Invalid token ID. Use the full format user@realm!token-name." >&2
  done
  while true; do
    ENV[PROXMOX_TOKEN_SECRET]="$(prompt_secret "Proxmox API token secret")"
    if [[ -n "${ENV[PROXMOX_TOKEN_SECRET]}" ]]; then
      break
    fi
    echo "Proxmox API token secret cannot be blank." >&2
  done
  ENV[PROXMOX_DEFAULT_NODE]="$(prompt_required "Proxmox default node")"
  ENV[PROXMOX_VERIFY_TLS]="$(prompt "PROXMOX_VERIFY_TLS" "true")"
  ENV[VM_NAME_PREFIX]="$(prompt "VM_NAME_PREFIX" "payload")"

  ENV[PROXMOX_SSH_HOST]="$(prompt "PROXMOX_SSH_HOST" "${ENV[PROXMOX_HOST]}")"
  ENV[PROXMOX_SSH_USER]="$(prompt "PROXMOX_SSH_USER" "root")"
  ENV[PROXMOX_SSH_KEY_PATH]="$(prompt "PROXMOX_SSH_KEY_PATH (leave blank for password auth)" "")"
  ENV[PROXMOX_SSH_PASSWORD]="$(prompt_secret "PROXMOX_SSH_PASSWORD (leave blank for key auth)" "")"
  ENV[PROXMOX_SSH_PORT]="$(prompt "PROXMOX_SSH_PORT" "22")"
fi

ENV[GUACAMOLE_BASE_URL]="$(prompt "GUACAMOLE_BASE_URL" "http://localhost:8080/guacamole")"
ENV[GUACAMOLE_PUBLIC_BASE_URL]="$(prompt "GUACAMOLE_PUBLIC_BASE_URL" "http://localhost:8080/guacamole")"
ENV[GUACAMOLE_DATA_SOURCE]="$(prompt "GUACAMOLE_DATA_SOURCE" "postgresql")"
ENV[GUACAMOLE_ADMIN_USER]="$(prompt "GUACAMOLE_ADMIN_USER" "guacadmin")"
ENV[GUACAMOLE_ADMIN_PASSWORD]="$(prompt_secret "GUACAMOLE_ADMIN_PASSWORD")"
ENV[SESSION_ENCRYPTION_KEY]="$(prompt_secret "SESSION_ENCRYPTION_KEY (64 hex characters)" "$(random_hex)")"

ENV[SLACK_REQUEST_URL]="$(prompt "SLACK_REQUEST_URL" "https://google.com")"
ENV[SESSION_LIFETIME_MS]="$(prompt "SESSION_LIFETIME_MS" "21600000")"
ENV[IDLE_TIMEOUT_MS]="$(prompt "IDLE_TIMEOUT_MS" "1800000")"
ENV[STUCK_TIMEOUT_MS]="$(prompt "STUCK_TIMEOUT_MS" "600000")"
ENV[REAPER_INTERVAL_MS]="$(prompt "REAPER_INTERVAL_MS" "60000")"
ENV[HEARTBEAT_INTERVAL_MS]="$(prompt "HEARTBEAT_INTERVAL_MS" "30000")"
ENV[MAX_SESSIONS_PER_USER]="$(prompt "MAX_SESSIONS_PER_USER" "2")"
ENV[IP_DISCOVERY_TIMEOUT_MS]="$(prompt "IP_DISCOVERY_TIMEOUT_MS" "120000")"
ENV[WARM_POOL_ENABLED]="$(prompt "WARM_POOL_ENABLED" "true")"
ENV[PAYLOAD_VM_MEMORY_BUDGET_MB]="$(prompt "PAYLOAD_VM_MEMORY_BUDGET_MB" "50000")"
ENV[WARM_MAX_AGE_MS]="$(prompt "WARM_MAX_AGE_MS" "7200000")"
ENV[MAX_CONCURRENT_WARM_BOOTS]="$(prompt "MAX_CONCURRENT_WARM_BOOTS" "2")"
ENV[RECONCILE_INTERVAL_MS]="$(prompt "RECONCILE_INTERVAL_MS" "15000")"
ENV[WARM_CPU_UNITS]="$(prompt "WARM_CPU_UNITS" "8")"
ENV[ACTIVE_CPU_UNITS]="$(prompt "ACTIVE_CPU_UNITS" "100")"
ENV[AI_BASE_URL]="$(prompt "AI_BASE_URL" "https://ai.hackclub.com/proxy/v1")"
ENV[AI_API_KEY]="$(prompt "AI_API_KEY (leave blank to disable AI)" "")"
ENV[AI_MODEL]="$(prompt "AI_MODEL" "deepseek/deepseek-v4-pro")"
ENV[REPO_MAX_CLONE_MB]="$(prompt "REPO_MAX_CLONE_MB" "350")"

ENV_FILE="$(prompt "Environment file" ".env")"
BACKUP=""
if [[ -f "$ENV_FILE" ]]; then
  BACKUP="${ENV_FILE}.backup.$(date +%Y%m%d%H%M%S)"
  cp "$ENV_FILE" "$BACKUP"
  echo "Backed up $ENV_FILE to $BACKUP"
fi

cat > "$ENV_FILE" <<EOF
# Generated by scripts/install.sh
AUTH_SECRET=${ENV[AUTH_SECRET]}
DATABASE_URL=${ENV[DATABASE_URL]}
REDIS_URL=${ENV[REDIS_URL]}
PROXMOX_HOST=${ENV[PROXMOX_HOST]}
PROXMOX_PORT=${ENV[PROXMOX_PORT]}
PROXMOX_TOKEN_ID=${ENV[PROXMOX_TOKEN_ID]}
PROXMOX_TOKEN_SECRET=${ENV[PROXMOX_TOKEN_SECRET]}
PROXMOX_DEFAULT_NODE=${ENV[PROXMOX_DEFAULT_NODE]}
PROXMOX_VERIFY_TLS=${ENV[PROXMOX_VERIFY_TLS]}
VM_NAME_PREFIX=${ENV[VM_NAME_PREFIX]}
PROXMOX_SSH_HOST=${ENV[PROXMOX_SSH_HOST]}
PROXMOX_SSH_USER=${ENV[PROXMOX_SSH_USER]}
PROXMOX_SSH_KEY_PATH=${ENV[PROXMOX_SSH_KEY_PATH]}
PROXMOX_SSH_PASSWORD=${ENV[PROXMOX_SSH_PASSWORD]}
PROXMOX_SSH_PORT=${ENV[PROXMOX_SSH_PORT]}
GUACAMOLE_BASE_URL=${ENV[GUACAMOLE_BASE_URL]}
GUACAMOLE_PUBLIC_BASE_URL=${ENV[GUACAMOLE_PUBLIC_BASE_URL]}
GUACAMOLE_DATA_SOURCE=${ENV[GUACAMOLE_DATA_SOURCE]}
GUACAMOLE_ADMIN_USER=${ENV[GUACAMOLE_ADMIN_USER]}
GUACAMOLE_ADMIN_PASSWORD=${ENV[GUACAMOLE_ADMIN_PASSWORD]}
SESSION_ENCRYPTION_KEY=${ENV[SESSION_ENCRYPTION_KEY]}
SLACK_REQUEST_URL=${ENV[SLACK_REQUEST_URL]}
SESSION_LIFETIME_MS=${ENV[SESSION_LIFETIME_MS]}
IDLE_TIMEOUT_MS=${ENV[IDLE_TIMEOUT_MS]}
STUCK_TIMEOUT_MS=${ENV[STUCK_TIMEOUT_MS]}
REAPER_INTERVAL_MS=${ENV[REAPER_INTERVAL_MS]}
HEARTBEAT_INTERVAL_MS=${ENV[HEARTBEAT_INTERVAL_MS]}
MAX_SESSIONS_PER_USER=${ENV[MAX_SESSIONS_PER_USER]}
IP_DISCOVERY_TIMEOUT_MS=${ENV[IP_DISCOVERY_TIMEOUT_MS]}
WARM_POOL_ENABLED=${ENV[WARM_POOL_ENABLED]}
PAYLOAD_VM_MEMORY_BUDGET_MB=${ENV[PAYLOAD_VM_MEMORY_BUDGET_MB]}
WARM_MAX_AGE_MS=${ENV[WARM_MAX_AGE_MS]}
MAX_CONCURRENT_WARM_BOOTS=${ENV[MAX_CONCURRENT_WARM_BOOTS]}
RECONCILE_INTERVAL_MS=${ENV[RECONCILE_INTERVAL_MS]}
WARM_CPU_UNITS=${ENV[WARM_CPU_UNITS]}
ACTIVE_CPU_UNITS=${ENV[ACTIVE_CPU_UNITS]}
AI_BASE_URL=${ENV[AI_BASE_URL]}
AI_API_KEY=${ENV[AI_API_KEY]}
AI_MODEL=${ENV[AI_MODEL]}
REPO_MAX_CLONE_MB=${ENV[REPO_MAX_CLONE_MB]}
EOF

chmod 600 "$ENV_FILE"
echo "Wrote $ENV_FILE"

if [[ "$DB_MODE" == "1" ]]; then
  cat >> "$ENV_FILE" <<EOF
POSTGRES_USER=${ENV[POSTGRES_USER]}
POSTGRES_PASSWORD=${ENV[POSTGRES_PASSWORD]}
POSTGRES_DB=${ENV[POSTGRES_DB]}
REDIS_PASSWORD=${ENV[REDIS_PASSWORD]}
EOF

  if confirm "Start PostgreSQL and Redis with Docker Compose?" "y"; then
    docker compose up -d db redis
  fi
fi

if confirm "Install pnpm dependencies?" "y"; then
  corepack enable
  pnpm install --frozen-lockfile
fi

if confirm "Apply database migrations?" "y"; then
  set -a
  source "$ENV_FILE"
  set +a
  pnpm db:migrate
fi

if confirm "Seed the default VM types and workspace?" "n"; then
  set -a
  source "$ENV_FILE"
  set +a
  pnpm db:seed
fi

echo
echo "Installation complete."
