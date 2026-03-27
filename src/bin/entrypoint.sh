#!/usr/bin/env bash
#
# Entrypoint script for containers
#

EXEC_DIR="$(realpath "$(dirname "$0")")"

message()
{
  echo "$(date -u '+%F %T'): $1"
}

FCGIWRAP_WORKERS=${FCGIWRAP_WORKERS:-12}

if [[ ! "$FCGIWRAP_WORKERS" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: FCGIWRAP_WORKERS must be a positive integer, got: '$FCGIWRAP_WORKERS'"
  exit 1
fi

# ============================================================================
# SIGNAL HANDLER
# ============================================================================

shutdown()
{
  local EXIT_CODE="$1"
  local EXIT_REASON="$2"
  message "$EXIT_REASON, shutting down..."

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
  exit "$EXIT_CODE"
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
fcgiwrap -s unix:/opt/overpass/run/fcgiwrap.socket -c "$FCGIWRAP_WORKERS" &
FCGI_PID=$!

# Start nginx
message "Starting nginx"
nginx -g 'daemon off;' &
NGINX_PID="$!"

# Start overpass
message "Starting Overpass"
"$EXEC_DIR/run_osm3s.sh" &
OSM3S_PID="$!"

message "All processes started"

while true; do
  wait -n -p EXITED_PID
  EXIT_CODE="$?"

  case "$EXITED_PID" in
    "$FCGI_PID")  EXITED_CHILD="fcgiwrap"; break ;;
    "$NGINX_PID") EXITED_CHILD="nginx"; break ;;
    "$OSM3S_PID") EXITED_CHILD="Overpass"; break ;;
  esac
done

shutdown "$EXIT_CODE" "$EXITED_CHILD exited unexpectedly with code $EXIT_CODE"
