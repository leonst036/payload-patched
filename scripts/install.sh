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

prompt_required_secret() {
  local label="$1"
  local value
  while true; do
    value="$(prompt_secret "$label")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return
    fi
    echo "$label cannot be blank." >&2
  done
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

env_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  value="${value//$'\n'/\\n}"
  printf '"%s"' "$value"
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
      local remote_command
      printf -v remote_command '%q ' "$@"
      remote_command="${remote_command% }"
      local ssh_args=(-p "${ENV[PROXMOX_SSH_PORT]}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
      if [[ -n "${ENV[PROXMOX_SSH_KEY_PATH]}" ]]; then
        ssh_args+=(-i "${ENV[PROXMOX_SSH_KEY_PATH]}")
        ssh "${ssh_args[@]}" "${ENV[PROXMOX_SSH_USER]}@${ENV[PROXMOX_SSH_HOST]}" "$remote_command"
      elif [[ -n "${ENV[PROXMOX_SSH_PASSWORD]}" ]]; then
        sshpass -p "${ENV[PROXMOX_SSH_PASSWORD]}" ssh -p "${ENV[PROXMOX_SSH_PORT]}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${ENV[PROXMOX_SSH_USER]}@${ENV[PROXMOX_SSH_HOST]}" "$remote_command"
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
    if [[ ! "${ENV[POSTGRES_USER]}" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
      echo "PostgreSQL username must start with a letter or underscore and contain only letters, numbers, underscores, or hyphens." >&2
      exit 1
    fi
    ENV[POSTGRES_DB]="$(prompt "PostgreSQL database name" "payload")"
    if [[ ! "${ENV[POSTGRES_DB]}" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
      echo "PostgreSQL database name must start with a letter or underscore and contain only letters, numbers, underscores, or hyphens." >&2
      exit 1
    fi
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
      if pve_exec pct status "$id" >/dev/null 2>&1; then
        echo "CT $id already exists." >&2
        if confirm "Destroy the existing CT $id and recreate it?" "n"; then
          pve_exec pct stop "$id" >/dev/null 2>&1 || true
          pve_exec pct destroy "$id" --purge
        else
          echo "Keeping the existing CT; stopped before CT creation." >&2
          exit 1
        fi
      fi
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
    pve_exec pct exec "$PG_CT_ID" -- bash -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib locales'
    pve_exec pct exec "$PG_CT_ID" -- bash -c 'sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen && locale-gen en_US.UTF-8'
    pve_exec pct exec "$PG_CT_ID" -- bash -c 'pg_dropcluster --stop 17 main >/dev/null 2>&1 || true; pg_createcluster 17 main --locale=en_US.UTF-8 --encoding=UTF8 --start'

    local_pg_ip="${PG_IP%%/*}"
    pg_sql_password="${ENV[POSTGRES_PASSWORD]//\'/\'\'}"
    pg_setup_sql=$(cat <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${ENV[POSTGRES_USER]}') THEN
    CREATE ROLE ${ENV[POSTGRES_USER]} LOGIN PASSWORD '${pg_sql_password}';
  ELSE
    ALTER ROLE ${ENV[POSTGRES_USER]} WITH LOGIN PASSWORD '${pg_sql_password}';
  END IF;
END
\$\$;
SELECT format('CREATE DATABASE %I OWNER %I', '${ENV[POSTGRES_DB]}', '${ENV[POSTGRES_USER]}')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${ENV[POSTGRES_DB]}')
\gexec
SQL
)
    pg_setup_b64="$(printf '%s' "$pg_setup_sql" | base64 | tr -d '\n')"
    pve_exec pct exec "$PG_CT_ID" -- bash -c "echo '$pg_setup_b64' | base64 -d | runuser -u postgres -- psql -v ON_ERROR_STOP=1"
    pve_exec pct exec "$PG_CT_ID" -- bash -c "sed -i \"s/^#*listen_addresses.*/listen_addresses = '\\''*'\\''/\" /etc/postgresql/*/main/postgresql.conf"
    pve_exec pct exec "$PG_CT_ID" -- bash -c "sed -i '/^host .*${ENV[POSTGRES_USER]} /d' /etc/postgresql/*/main/pg_hba.conf"
    pve_exec pct exec "$PG_CT_ID" -- bash -c "echo 'host ${ENV[POSTGRES_DB]} ${ENV[POSTGRES_USER]} 0.0.0.0/0 scram-sha-256' >> /etc/postgresql/*/main/pg_hba.conf"
    pve_exec pct exec "$PG_CT_ID" -- bash -c 'pg_ctlcluster 17 main restart'
    if ! pve_exec pct exec "$PG_CT_ID" -- bash -c 'for i in $(seq 1 30); do pg_isready -q -h 127.0.0.1 -p 5432 && exit 0; sleep 1; done; exit 1'; then
      echo "PostgreSQL in CT $PG_CT_ID did not become ready." >&2
      pve_exec pct exec "$PG_CT_ID" -- bash -c 'systemctl status postgresql --no-pager || true'
      exit 1
    fi
    pve_exec pct exec "$PG_CT_ID" -- bash -c "PGPASSWORD='${ENV[POSTGRES_PASSWORD]}' psql -h 127.0.0.1 -U '${ENV[POSTGRES_USER]}' -d '${ENV[POSTGRES_DB]}' -tAc 'SELECT 1' | grep -q 1"

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
ENV[GUACAMOLE_ADMIN_PASSWORD]="$(prompt_required_secret "GUACAMOLE_ADMIN_PASSWORD")"
while true; do
  ENV[SESSION_ENCRYPTION_KEY]="$(prompt_secret "SESSION_ENCRYPTION_KEY (64 hex characters)" "$(random_hex)")"
  if [[ "${ENV[SESSION_ENCRYPTION_KEY]}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    break
  fi
  echo "SESSION_ENCRYPTION_KEY must be exactly 64 hexadecimal characters." >&2
done

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
AUTH_SECRET=$(env_quote "${ENV[AUTH_SECRET]}")
DATABASE_URL=$(env_quote "${ENV[DATABASE_URL]}")
REDIS_URL=$(env_quote "${ENV[REDIS_URL]}")
PROXMOX_HOST=$(env_quote "${ENV[PROXMOX_HOST]}")
PROXMOX_PORT=$(env_quote "${ENV[PROXMOX_PORT]}")
PROXMOX_TOKEN_ID=$(env_quote "${ENV[PROXMOX_TOKEN_ID]}")
PROXMOX_TOKEN_SECRET=$(env_quote "${ENV[PROXMOX_TOKEN_SECRET]}")
PROXMOX_DEFAULT_NODE=$(env_quote "${ENV[PROXMOX_DEFAULT_NODE]}")
PROXMOX_VERIFY_TLS=$(env_quote "${ENV[PROXMOX_VERIFY_TLS]}")
VM_NAME_PREFIX=$(env_quote "${ENV[VM_NAME_PREFIX]}")
PROXMOX_SSH_HOST=$(env_quote "${ENV[PROXMOX_SSH_HOST]}")
PROXMOX_SSH_USER=$(env_quote "${ENV[PROXMOX_SSH_USER]}")
PROXMOX_SSH_KEY_PATH=$(env_quote "${ENV[PROXMOX_SSH_KEY_PATH]}")
PROXMOX_SSH_PASSWORD=$(env_quote "${ENV[PROXMOX_SSH_PASSWORD]}")
PROXMOX_SSH_PORT=$(env_quote "${ENV[PROXMOX_SSH_PORT]}")
GUACAMOLE_BASE_URL=$(env_quote "${ENV[GUACAMOLE_BASE_URL]}")
GUACAMOLE_PUBLIC_BASE_URL=$(env_quote "${ENV[GUACAMOLE_PUBLIC_BASE_URL]}")
GUACAMOLE_DATA_SOURCE=$(env_quote "${ENV[GUACAMOLE_DATA_SOURCE]}")
GUACAMOLE_ADMIN_USER=$(env_quote "${ENV[GUACAMOLE_ADMIN_USER]}")
GUACAMOLE_ADMIN_PASSWORD=$(env_quote "${ENV[GUACAMOLE_ADMIN_PASSWORD]}")
SESSION_ENCRYPTION_KEY=$(env_quote "${ENV[SESSION_ENCRYPTION_KEY]}")
SLACK_REQUEST_URL=$(env_quote "${ENV[SLACK_REQUEST_URL]}")
SESSION_LIFETIME_MS=$(env_quote "${ENV[SESSION_LIFETIME_MS]}")
IDLE_TIMEOUT_MS=$(env_quote "${ENV[IDLE_TIMEOUT_MS]}")
STUCK_TIMEOUT_MS=$(env_quote "${ENV[STUCK_TIMEOUT_MS]}")
REAPER_INTERVAL_MS=$(env_quote "${ENV[REAPER_INTERVAL_MS]}")
HEARTBEAT_INTERVAL_MS=$(env_quote "${ENV[HEARTBEAT_INTERVAL_MS]}")
MAX_SESSIONS_PER_USER=$(env_quote "${ENV[MAX_SESSIONS_PER_USER]}")
IP_DISCOVERY_TIMEOUT_MS=$(env_quote "${ENV[IP_DISCOVERY_TIMEOUT_MS]}")
WARM_POOL_ENABLED=$(env_quote "${ENV[WARM_POOL_ENABLED]}")
PAYLOAD_VM_MEMORY_BUDGET_MB=$(env_quote "${ENV[PAYLOAD_VM_MEMORY_BUDGET_MB]}")
WARM_MAX_AGE_MS=$(env_quote "${ENV[WARM_MAX_AGE_MS]}")
MAX_CONCURRENT_WARM_BOOTS=$(env_quote "${ENV[MAX_CONCURRENT_WARM_BOOTS]}")
RECONCILE_INTERVAL_MS=$(env_quote "${ENV[RECONCILE_INTERVAL_MS]}")
WARM_CPU_UNITS=$(env_quote "${ENV[WARM_CPU_UNITS]}")
ACTIVE_CPU_UNITS=$(env_quote "${ENV[ACTIVE_CPU_UNITS]}")
AI_BASE_URL=$(env_quote "${ENV[AI_BASE_URL]}")
AI_API_KEY=$(env_quote "${ENV[AI_API_KEY]}")
AI_MODEL=$(env_quote "${ENV[AI_MODEL]}")
REPO_MAX_CLONE_MB=$(env_quote "${ENV[REPO_MAX_CLONE_MB]}")
EOF

chmod 600 "$ENV_FILE"
echo "Wrote $ENV_FILE"

if [[ "$DB_MODE" == "1" ]]; then
  cat >> "$ENV_FILE" <<EOF
POSTGRES_USER=$(env_quote "${ENV[POSTGRES_USER]}")
POSTGRES_PASSWORD=$(env_quote "${ENV[POSTGRES_PASSWORD]}")
POSTGRES_DB=$(env_quote "${ENV[POSTGRES_DB]}")
REDIS_PASSWORD=$(env_quote "${ENV[REDIS_PASSWORD]}")
EOF

  if confirm "Start PostgreSQL and Redis with Docker Compose?" "y"; then
    docker compose up -d db redis
  fi
fi

if confirm "Install pnpm dependencies?" "y"; then
  if ! command -v node >/dev/null 2>&1; then
    echo "Node.js is required but was not found."
    if command -v apt-get >/dev/null 2>&1; then
      if confirm "Install Node.js 20 and Corepack with apt?" "y"; then
        apt-get update
        apt-get install -y curl ca-certificates
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
      else
        echo "Install Node.js 20, then rerun the installer." >&2
        exit 1
      fi
    else
      echo "Install Node.js 20, then rerun the installer." >&2
      exit 1
    fi
  fi

  if command -v corepack >/dev/null 2>&1; then
    corepack enable
    corepack prepare pnpm@9.15.0 --activate
  elif command -v npm >/dev/null 2>&1; then
    npm install --global pnpm@9.15.0
  else
    echo "Corepack/npm is unavailable. Install Node.js with Corepack." >&2
    exit 1
  fi

  hash -r
  command -v pnpm >/dev/null 2>&1 || export PATH="/usr/local/bin:/usr/bin:$PATH"
  hash -r
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "pnpm was installed but is not available in PATH." >&2
    exit 1
  fi
  pnpm install --frozen-lockfile
fi

if confirm "Apply database migrations?" "y"; then
  set -a
  source "$ENV_FILE"
  set +a
  if [[ "$DB_MODE" == "2" ]]; then
    if [[ "$DATABASE_URL" =~ @([^:/]+)(:[0-9]+)?/ ]]; then
      db_host="${BASH_REMATCH[1]}"
      echo "Checking PostgreSQL connectivity to $db_host:5432..."
      if ! timeout 10 bash -c "exec 3<>/dev/tcp/$db_host/5432" 2>/dev/null; then
        echo "Cannot reach PostgreSQL at $db_host:5432 from the Payload VM." >&2
        echo "Check the CT IP, VM network mode, bridge/VLAN, firewall, and UFW rules." >&2
        exit 1
      fi
      echo "PostgreSQL port is reachable."
    fi
  fi
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
