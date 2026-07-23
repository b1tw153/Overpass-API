#!/usr/bin/env bash
#
# Entrypoint script for containers
#

GO_ZOMBIE=false

EXEC_DIR="$(dirname "$(realpath "$0")")"

message()
{
  echo "$(date -u '+%F %T'): $1"
}

# Validate an IP address or CIDR netblock with the same library (Net::CIDR) that
# munin-node uses to enforce its access-control list.
munin_valid_cidr()
{
  perl -MNet::CIDR=cidrvalidate -e 'exit(defined cidrvalidate($ARGV[0]) ? 0 : 1)' "$1"
}

message "-----------------------------------"
message "Starting entrypoint ($0)"
message "-----------------------------------"
while IFS='=' read -r name value; do
  message "$(printf '%-35s %s' "$name" "$value")"
done < <(env | sort)
message "-----------------------------------"

CGROUP_CPU_MAX=$(cat /sys/fs/cgroup/cpu.max 2>/dev/null)
if [[ "$CGROUP_CPU_MAX" =~ ^([0-9]+)[[:space:]]([0-9]+)$ ]]; then
  CPU_COUNT=$(( BASH_REMATCH[1] / BASH_REMATCH[2] ))
else
  CPU_COUNT=$(nproc)
fi

FCGIWRAP_WORKERS=${FCGIWRAP_WORKERS:-$(( CPU_COUNT + 1 ))}

if [[ ! "$FCGIWRAP_WORKERS" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: FCGIWRAP_WORKERS must be a positive integer, got: '$FCGIWRAP_WORKERS'"
  exit 1
fi

export FCGIWRAP_WORKERS

NGINX_FASTCGI_TIMEOUT=${NGINX_FASTCGI_TIMEOUT:-300}

if [[ ! "$NGINX_FASTCGI_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: NGINX_FASTCGI_TIMEOUT must be a positive integer, got: '$NGINX_FASTCGI_TIMEOUT'"
  exit 1
fi

export NGINX_FASTCGI_TIMEOUT

NGINX_CONNECTION_QUEUE=${NGINX_CONNECTION_QUEUE:-$(( CPU_COUNT * 7 - 1 ))}

if [[ ! "$NGINX_CONNECTION_QUEUE" =~ ^[0-9]+$ ]]; then
  message "ERROR: NGINX_CONNECTION_QUEUE must be a non-negative integer, got: '$NGINX_CONNECTION_QUEUE'"
  exit 1
fi

NGINX_MAX_CONN=$(( FCGIWRAP_WORKERS + NGINX_CONNECTION_QUEUE ))
export NGINX_MAX_CONN

if [[ -n "${NGINX_CLIENT_CONN_LIMIT:-}" ]]; then
  if [[ ! "$NGINX_CLIENT_CONN_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
    message "ERROR: NGINX_CLIENT_CONN_LIMIT must be a positive integer, got: '$NGINX_CLIENT_CONN_LIMIT'"
    exit 1
  fi
  NGINX_LIMIT_CONN_ZONE="limit_conn_zone \$binary_remote_addr zone=client_conn:10m;"
  NGINX_LIMIT_CONN_CLIENT="limit_conn client_conn ${NGINX_CLIENT_CONN_LIMIT};"
else
  NGINX_LIMIT_CONN_ZONE=""
  NGINX_LIMIT_CONN_CLIENT=""
fi
export NGINX_LIMIT_CONN_ZONE NGINX_LIMIT_CONN_CLIENT

if [[ -n "${NGINX_CLIENT_REQ_RATE:-}" ]]; then
  if [[ ! "$NGINX_CLIENT_REQ_RATE" =~ ^[1-9][0-9]*r/[sm]$ ]]; then
    message "ERROR: NGINX_CLIENT_REQ_RATE must be a rate like 10r/s or 30r/m, got: '$NGINX_CLIENT_REQ_RATE'"
    exit 1
  fi
  NGINX_CLIENT_REQ_BURST=${NGINX_CLIENT_REQ_BURST:-0}
  if [[ ! "$NGINX_CLIENT_REQ_BURST" =~ ^[0-9]+$ ]]; then
    message "ERROR: NGINX_CLIENT_REQ_BURST must be a non-negative integer, got: '$NGINX_CLIENT_REQ_BURST'"
    exit 1
  fi
  NGINX_CLIENT_REQ_DELAY=${NGINX_CLIENT_REQ_DELAY:-$NGINX_CLIENT_REQ_BURST}
  if [[ ! "$NGINX_CLIENT_REQ_DELAY" =~ ^[0-9]+$ ]]; then
    message "ERROR: NGINX_CLIENT_REQ_DELAY must be a non-negative integer, got: '$NGINX_CLIENT_REQ_DELAY'"
    exit 1
  fi
  NGINX_LIMIT_REQ_ZONE="limit_req_zone \$binary_remote_addr zone=client_req:10m rate=${NGINX_CLIENT_REQ_RATE};"
  NGINX_LIMIT_REQ_CLIENT="limit_req zone=client_req burst=${NGINX_CLIENT_REQ_BURST} delay=${NGINX_CLIENT_REQ_DELAY};"
else
  NGINX_LIMIT_REQ_ZONE=""
  NGINX_LIMIT_REQ_CLIENT=""
fi
export NGINX_LIMIT_REQ_ZONE NGINX_LIMIT_REQ_CLIENT

if [[ -z "${DISPATCHER_BASE_SPACE:-}" ]]; then
  DISPATCHER_BASE_SPACE=824633720832
  export DISPATCHER_BASE_SPACE
fi

# Munin monitoring is opt-in: the node starts only when the operator names who
# may poll it via MUNIN_NODE_CIDR_ALLOW. An empty allow-list leaves it stopped.
MUNIN_NODE_CIDR_ALLOW=${MUNIN_NODE_CIDR_ALLOW:-}
MUNIN_NODE_CIDR_DENY=${MUNIN_NODE_CIDR_DENY:-}

if [[ -n "$MUNIN_NODE_CIDR_ALLOW" ]]; then
  MUNIN_NODE_LOG_LEVEL=${MUNIN_NODE_LOG_LEVEL:-4}
  if [[ ! "$MUNIN_NODE_LOG_LEVEL" =~ ^[0-9]+$ ]]; then
    message "ERROR: MUNIN_NODE_LOG_LEVEL must be a non-negative integer, got: '$MUNIN_NODE_LOG_LEVEL'"
    exit 1
  fi

  MUNIN_NODE_PORT=${MUNIN_NODE_PORT:-4949}
  if [[ ! "$MUNIN_NODE_PORT" =~ ^[1-9][0-9]*$ ]]; then
    message "ERROR: MUNIN_NODE_PORT must be a positive integer, got: '$MUNIN_NODE_PORT'"
    exit 1
  fi

  MUNIN_NODE_HOST_NAME=${MUNIN_NODE_HOST_NAME:-$HOSTNAME}
  if [[ ! "$MUNIN_NODE_HOST_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; then
    message "ERROR: MUNIN_NODE_HOST_NAME must be a hostname or FQDN, got: '$MUNIN_NODE_HOST_NAME'"
    exit 1
  fi

  # Single IPv4 bind address, default all interfaces.
  MUNIN_NODE_HOST=${MUNIN_NODE_HOST:-0.0.0.0}
  if [[ "$MUNIN_NODE_HOST" == *[[:space:]]* || "$MUNIN_NODE_HOST" == *:* \
        || "$MUNIN_NODE_HOST" == */* ]] || ! munin_valid_cidr "$MUNIN_NODE_HOST"; then
    message "ERROR: MUNIN_NODE_HOST must be a single IPv4 address, got: '$MUNIN_NODE_HOST'"
    exit 1
  fi

  # Validate the access-control lists, then render the cidr_allow / cidr_deny
  # block from them.
  read -ra MUNIN_ALLOW_CIDRS <<< "$MUNIN_NODE_CIDR_ALLOW"
  for cidr in "${MUNIN_ALLOW_CIDRS[@]}"; do
    if ! munin_valid_cidr "$cidr"; then
      message "ERROR: MUNIN_NODE_CIDR_ALLOW entries must be CIDR netblocks, got: '$cidr'"
      exit 1
    fi
  done

  read -ra MUNIN_DENY_CIDRS <<< "$MUNIN_NODE_CIDR_DENY"
  for cidr in "${MUNIN_DENY_CIDRS[@]}"; do
    if ! munin_valid_cidr "$cidr"; then
      message "ERROR: MUNIN_NODE_CIDR_DENY entries must be CIDR netblocks, got: '$cidr'"
      exit 1
    fi
  done

  MUNIN_NODE_ACL=$(
    for cidr in "${MUNIN_ALLOW_CIDRS[@]}"; do
      printf 'cidr_allow %s\n' "$cidr"
    done
    for cidr in "${MUNIN_DENY_CIDRS[@]}"; do
      printf 'cidr_deny %s\n' "$cidr"
    done
  )

  export MUNIN_NODE_LOG_LEVEL MUNIN_NODE_HOST_NAME MUNIN_NODE_ACL MUNIN_NODE_HOST MUNIN_NODE_PORT
fi

# ============================================================================
# SIGNAL HANDLER
# ============================================================================

shutdown()
{
  local EXIT_CODE="$1"
  local EXIT_REASON="$2"
  message "$EXIT_REASON, shutting down..."

  if [[ -n "$MUNIN_PID" ]] && kill -0 "$MUNIN_PID" 2>/dev/null; then
    message "Stopping munin-node"
    kill "$MUNIN_PID" 2>/dev/null
    wait "$MUNIN_PID"
    message "Stopped munin-node"
  fi
  MUNIN_PID=

  if [[ -n "$NGINX_PID" ]] && kill -0 "$NGINX_PID" 2>/dev/null; then
    message "Stopping nginx"
    kill "$NGINX_PID" 2>/dev/null
    wait "$NGINX_PID"
    message "Stopped nginx"
  fi
  NGINX_PID=

  if [[ -n "$OSM3S_PID" ]] && kill -0 "$OSM3S_PID" 2>/dev/null; then
    message "Stopping Overpass; this may take a while"
    message "Make sure the container host allows enough time for Overpass to finish its database transactions"
    message "Docker: --stop-timeout 600"
    message "Docker Compose: stop_grace_period: 600s"
    message "Kubernetes: terminationGracePeriodSeconds: 600"
    kill "$OSM3S_PID" 2>/dev/null
    wait "$OSM3S_PID"
    message "Stopped Overpass"
  fi
  OSM3S_PID=

  if [[ -n "$FCGI_PID" ]] && kill -0 "$FCGI_PID" 2>/dev/null; then
    message "Stopping fcgi"
    kill "$FCGI_PID" 2>/dev/null
    wait "$FCGI_PID"
    message "Stopped fcgi"
  fi
  FCGI_PID=

  message "Shutdown complete"
  if $GO_ZOMBIE; then
    GO_ZOMBIE=false
    while true; do
      sleep 60 &
      wait $!
    done
  else
    exit "$EXIT_CODE"
  fi
}

trap 'shutdown 143 "SIGTERM received"' SIGTERM
trap 'shutdown 130 "SIGINT received"'  SIGINT
trap 'shutdown 129 "SIGHUP received"'  SIGHUP

# ============================================================================
# CONTAINER SETUP
# ============================================================================

# Copy default rules into the database directory, skipping files that already exist
mkdir -p "$OVERPASS_DB_DIR/rules"
for rule_file in "/opt/overpass/rules"/*; do
  [[ -e "$rule_file" ]] || continue
  dest="$OVERPASS_DB_DIR/rules/$(basename "$rule_file")"
  if [[ ! -e "$dest" ]]; then
    message "Installing default rule: $(basename "$rule_file")"
    cp "$rule_file" "$dest"
  fi
done

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Start fcgiwrap for CGI script handling
message "Starting fcgi"
rm -f /opt/overpass/run/fcgiwrap.socket
fcgiwrap -s unix:/opt/overpass/run/fcgiwrap.socket -c "$FCGIWRAP_WORKERS" >> "$OVERPASS_LOG_DIR/fcgiwrap.out" 2>&1 &
FCGI_PID=$!
echo "$FCGI_PID" > /opt/overpass/run/fcgiwrap.pid

# Render nginx config from template
envsubst '${FCGIWRAP_WORKERS} ${NGINX_FASTCGI_TIMEOUT} ${NGINX_MAX_CONN} ${NGINX_LIMIT_CONN_ZONE} ${NGINX_LIMIT_CONN_CLIENT} ${NGINX_LIMIT_REQ_ZONE} ${NGINX_LIMIT_REQ_CLIENT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# Start nginx
message "Starting nginx"
nginx -g 'daemon off;' >> "$OVERPASS_LOG_DIR/nginx.out" 2>&1 &
NGINX_PID="$!"

# Start overpass
message "Starting Overpass"
"$EXEC_DIR/run_osm3s.sh" &
OSM3S_PID="$!"

# Start munin-node if monitoring is enabled (not load-bearing for serving)
if [[ -n "$MUNIN_NODE_CIDR_ALLOW" ]]; then
  message "Starting munin-node"
  envsubst '${MUNIN_NODE_LOG_LEVEL} ${MUNIN_NODE_HOST_NAME} ${MUNIN_NODE_ACL} ${MUNIN_NODE_HOST} ${MUNIN_NODE_PORT}' \
    < /etc/munin/munin-node.conf.template > /etc/munin/munin-node.conf
  munin-node --config /etc/munin/munin-node.conf >> "$OVERPASS_LOG_DIR/munin-node.out" 2>&1 &
  MUNIN_PID="$!"
fi

message "All processes started"

while true; do
  wait -n -p EXITED_PID
  EXIT_CODE="$?"

  case "$EXITED_PID" in
    "$FCGI_PID")  EXITED_CHILD="fcgiwrap"; GO_ZOMBIE=true; break ;;
    "$NGINX_PID") EXITED_CHILD="nginx";    GO_ZOMBIE=true; break ;;
    "$OSM3S_PID") EXITED_CHILD="Overpass"; GO_ZOMBIE=true; break ;;
    "$MUNIN_PID")
      message "WARNING: munin-node exited with code $EXIT_CODE; monitoring has stopped"
      MUNIN_PID=
      ;;
  esac
done

shutdown "$EXIT_CODE" "$EXITED_CHILD exited unexpectedly with code $EXIT_CODE"
