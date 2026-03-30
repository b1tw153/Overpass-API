#!/usr/bin/env bash

# Copyright 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018 Roland Olbricht et al.
# With improvements in 2025, 2026 by Kai Johnson
#
# This file is part of Overpass_API.
#
# Overpass_API is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# Overpass_API is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Overpass_API. If not, see <https://www.gnu.org/licenses/>.

usage() {
  cat <<EOF
Usage: $0
    --run=REPLICATE_ID 
    --db-dir=DB_DIR 
    --diff-dir=OVERPASS_DIFF_DIR
    --diff-url=OVERPASS_DIFF_URL
    --meta=no|yes|attic
    --areas=no|yes

--run=REPLICATE_ID
    The replicate ID to start fetching diffs from or "auto"

--db-dir=DB_DIR
    The directory where the database is stored.

--diff-dir=OVERPASS_DIFF_DIR
    The directory where the diffs are stored.

--diff-url=OVERPASS_DIFF_URL
    Specify the URL to download the diffs from. The usual URL is
    https://planet.openstreetmap.org/replication/minute/

--meta=attic|yes|no
    Keep or discard meta/attic data in the database.

--areas=yes|no
    Create or skip derived area data.

Environment variables (overridden by arguments):
  OVERPASS_REPLICATE_ID         Same as --run
  OVERPASS_DB_DIR               Same as --db-dir
  OVERPASS_DIFF_DIR             Same as --diff-dir
  OVERPASS_DIFF_URL             Same as --diff-url
  OVERPASS_META_MODE            Same as --meta
  OVERPASS_AREAS                Same as --areas

Environment variables (no argument equivalent):
  OVERPASS_UPDATE_FREQUENCY     Update interval in seconds (default: 60)
  OVERPASS_SOCKET_DIR           Directory for dispatcher socket files (default: DB_DIR)
  OVERPASS_STALL_MULTIPLIER     Stall detection threshold as a multiple of update
                                frequency
  OVERPASS_CLEANUP_INTERVAL     How often to run diff cleanup, in hours (default: 24)
  OVERPASS_CLEANUP_KEEP_HOURS   How many hours of diff data to retain (default: 72)
  OVERPASS_BACKUP_DIR           Directory for database backups
  OVERPASS_BACKUP_TIME          Time of day to run backup (00:00-23:59)
  OVERPASS_BACKUP_DAY           Day to run backup: MON|TUE|WED|THU|FRI|SAT|SUN or 1-31
                                implies OVERPASS_BACKUP_TIME 00:00 if OVERPASS_BACKUP_TIME
                                is not specified
  OVERPASS_LOG_DIR              Directory containing web server logs (if run_osm3s.sh should rotate them)
  DISPATCHER_BASE_SPACE         Base dispatcher shared memory in bytes (default: 12884901888)
  DISPATCHER_AREAS_SPACE        Areas dispatcher shared memory in bytes (default: 4294967296)
  DISPATCHER_TIME               Dispatcher time limit (default: 262144)
  DISPATCHER_RATE_LIMIT         Dispatcher rate limit; 0 means unlimited (default: 0)
  DISPATCHER_ALLOW_DUPLICATE_QUERIES
                                Allow duplicate queries: yes|no (default: yes)
  
See usage for fetch_osc.sh, apply_osc_to_db.sh, rules_loop.sh, and backup.sh for
additional environment variable parameters.
EOF
}

print_help() {
  cat <<EOF
Help: $0
    ...
    ... set --stop-timeout to something big in Docker ...
EOF
}

sleep_with_interrupts()
{
  sleep "$1" &
  wait $!
}

message()
{
  echo "$(date -u '+%F %T'): $1"
}

# ============================================================================
# ARGUMENT PARAMETERS
# ============================================================================

PARSED=$(getopt \
  --options '' \
  --longoptions 'run:,db-dir:,diff-dir:,diff-url:,meta:,areas:,help' \
  --name "$0" \
  -- "$@") || { usage; exit 1; }

eval set -- "$PARSED"

START_ID="${OVERPASS_REPLICATE_ID:-}"
OVERPASS_DB_DIR="${OVERPASS_DB_DIR:-}"
OVERPASS_DIFF_DIR="${OVERPASS_DIFF_DIR:-}"
OVERPASS_DIFF_URL="${OVERPASS_DIFF_URL:-}"
OVERPASS_META_MODE="${OVERPASS_META_MODE:-}"
AREAS="${OVERPASS_AREAS:-}"

while true; do
  case "$1" in
    --run)           START_ID="$2";             shift 2 ;;
    --db-dir)        OVERPASS_DB_DIR="$2";      shift 2 ;;
    --diff-dir)      OVERPASS_DIFF_DIR="$2";    shift 2 ;;
    --diff-url)      OVERPASS_DIFF_URL="$2";    shift 2 ;;
    --meta)          OVERPASS_META_MODE="$2";   shift 2 ;;
    --areas)         AREAS="$2";                shift 2 ;;
    --help)          print_help;                exit  0 ;;
    --)              shift; break ;;
  esac
done

if [[ -z $START_ID ]]; then
  message "ERROR: --run is required"
  usage
  exit 1
fi

if [[ "$START_ID" != "auto" && ! "$START_ID" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: Invalid --run value '$START_ID': must be a positive integer or 'auto'"
  usage
  exit 1
fi

if [[ -z $OVERPASS_DB_DIR ]]; then
  message "ERROR: --db-dir is required"
  usage
  exit 1
fi

if ! [[ -d $OVERPASS_DB_DIR && -w $OVERPASS_DB_DIR ]]; then
  message "ERROR: --db-dir '$OVERPASS_DB_DIR' is not a writeable directory"
  usage
  exit 1
fi
    
if [[ -z $OVERPASS_DIFF_DIR ]]; then
  message "ERROR: --diff-dir is required"
  usage
  exit 1
fi

if ! [[ -d "$OVERPASS_DIFF_DIR" && -w "$OVERPASS_DIFF_DIR" ]]; then
  message "ERROR: --diff-dir '$OVERPASS_DIFF_DIR' is not a writeable directory"
  usage
  exit 1
fi

if [[ -z $OVERPASS_DIFF_URL ]]; then
  message "ERROR: --diff-url is required"
  usage
  exit 1
fi

if [[ ! "$OVERPASS_DIFF_URL" =~ ^https?:// ]]; then
  message "ERROR: Invalid OVERPASS_DIFF_URL '$OVERPASS_DIFF_URL': must start with http:// or https://"
  usage
  exit 1
fi

if [[ $OVERPASS_META_MODE != "attic" && $OVERPASS_META_MODE != "yes" && $OVERPASS_META_MODE != "no" ]]; then
  message "ERROR: --meta must be 'attic', 'yes', or 'no'"
  usage
  exit 1
fi

if [[ $AREAS != "yes" && $AREAS != "no" ]]; then
  message "ERROR: --areas must be 'yes' or 'no'"
  usage
  exit 1
fi

EXEC_DIR="$(realpath "$(dirname "$0")")"
OVERPASS_DIFF_DIR="$(realpath "$OVERPASS_DIFF_DIR")"
OVERPASS_DB_DIR="$(realpath "$OVERPASS_DB_DIR")"

# ============================================================================
# ENVIRONMENT VARIABLE PARAMETERS
# ============================================================================

OVERPASS_UPDATE_FREQUENCY=${OVERPASS_UPDATE_FREQUENCY:-60}
OVERPASS_SOCKET_DIR=${OVERPASS_SOCKET_DIR:-"$OVERPASS_DB_DIR"}
OVERPASS_STALL_MULTIPLIER=${OVERPASS_STALL_MULTIPLIER:-}
OVERPASS_CLEANUP_INTERVAL=${OVERPASS_CLEANUP_INTERVAL:-24}
OVERPASS_CLEANUP_KEEP_HOURS=${OVERPASS_CLEANUP_KEEP_HOURS:-72}
OVERPASS_BACKUP_DIR=${OVERPASS_BACKUP_DIR:-}
OVERPASS_BACKUP_TIME=${OVERPASS_BACKUP_TIME:-}
OVERPASS_BACKUP_DAY=${OVERPASS_BACKUP_DAY:-}
OVERPASS_LOG_DIR=${OVERPASS_LOG_DIR:-}
DISPATCHER_BASE_SPACE=${DISPATCHER_BASE_SPACE:-12884901888}
DISPATCHER_AREAS_SPACE=${DISPATCHER_AREAS_SPACE:-4294967296}
DISPATCHER_TIME=${DISPATCHER_TIME:-262144}
DISPATCHER_RATE_LIMIT=${DISPATCHER_RATE_LIMIT:-0}
DISPATCHER_ALLOW_DUPLICATE_QUERIES=${DISPATCHER_ALLOW_DUPLICATE_QUERIES:-yes}

if [[ ! "$OVERPASS_UPDATE_FREQUENCY" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: OVERPASS_UPDATE_FREQUENCY must be a positive integer, got: '$OVERPASS_UPDATE_FREQUENCY'"
  usage
  exit 1
fi

if [[ "$OVERPASS_UPDATE_FREQUENCY" -ne 60 && "$OVERPASS_UPDATE_FREQUENCY" -ne 3600 && "$OVERPASS_UPDATE_FREQUENCY" -ne 86400 ]]; then
  message "WARNING: Unexpected OVERPASS_UPDATE_FREQUENCY: $OVERPASS_UPDATE_FREQUENCY (expected: 60, 3600, 86400)"
fi

if ! [[ -d "$OVERPASS_SOCKET_DIR" && -w "$OVERPASS_SOCKET_DIR" ]]; then
  message "ERROR: OVERPASS_SOCKET_DIR '$OVERPASS_SOCKET_DIR' is not a writeable directory"
  usage
  exit 1
fi

OVERPASS_SOCKET_DIR="$(realpath "$OVERPASS_SOCKET_DIR")"

if [[ -n "$OVERPASS_STALL_MULTIPLIER" && ! "$OVERPASS_STALL_MULTIPLIER" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: OVERPASS_STALL_MULTIPLIER must be a positive integer, got: '$OVERPASS_STALL_MULTIPLIER'"
  usage
  exit 1
fi

if [[ ! "$OVERPASS_CLEANUP_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: OVERPASS_CLEANUP_INTERVAL must be a positive integer, got: '$OVERPASS_CLEANUP_INTERVAL'"
  usage
  exit 1
fi

if [[ ! "$OVERPASS_CLEANUP_KEEP_HOURS" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: OVERPASS_CLEANUP_KEEP_HOURS must be a positive integer, got: '$OVERPASS_CLEANUP_KEEP_HOURS'"
  usage
  exit 1
fi

BACKUP="no"
if [[ -n "$OVERPASS_BACKUP_DIR" ]]; then
  if ! [[ -d "$OVERPASS_BACKUP_DIR" && -w "$OVERPASS_BACKUP_DIR" ]]; then
    message "ERROR: OVERPASS_BACKUP_DIR '$OVERPASS_BACKUP_DIR' is not a writeable directory"
    usage
    exit 1
  fi

  OVERPASS_BACKUP_DIR="$(realpath "$OVERPASS_BACKUP_DIR")"
  
  if [[ -n "$OVERPASS_BACKUP_TIME" || -n "$OVERPASS_BACKUP_DAY" ]]; then
    BACKUP="yes"
  else
    message "INFO: Specify OVERPASS_BACKUP_TIME or OVERPASS_BACKUP_DAY to enable backups"
  fi
fi

if [[ -n "$OVERPASS_LOG_DIR" ]]; then
  if ! [[ -d "$OVERPASS_LOG_DIR" && -w "$OVERPASS_LOG_DIR" ]]; then
    message "ERROR: OVERPASS_LOG_DIR '$OVERPASS_LOG_DIR' is not a writeable directory"
    usage
    exit 1
  fi

  OVERPASS_LOG_DIR="$(realpath "$OVERPASS_LOG_DIR")"
fi

if [[ ! "$DISPATCHER_BASE_SPACE" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: DISPATCHER_BASE_SPACE must be a positive integer, got: '$DISPATCHER_BASE_SPACE'"
  usage
  exit 1
fi

if [[ ! "$DISPATCHER_AREAS_SPACE" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: DISPATCHER_AREAS_SPACE must be a positive integer, got: '$DISPATCHER_AREAS_SPACE'"
  usage
  exit 1
fi

if [[ ! "$DISPATCHER_TIME" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: DISPATCHER_TIME must be a positive integer, got: '$DISPATCHER_TIME'"
  usage
  exit 1
fi

if [[ ! "$DISPATCHER_RATE_LIMIT" =~ ^[0-9]+$ ]]; then
  message "ERROR: DISPATCHER_RATE_LIMIT must be a non-negative integer, got: '$DISPATCHER_RATE_LIMIT'"
  usage
  exit 1
fi

if [[ "$DISPATCHER_ALLOW_DUPLICATE_QUERIES" != "yes" && "$DISPATCHER_ALLOW_DUPLICATE_QUERIES" != "no" ]]; then
  message "ERROR: DISPATCHER_ALLOW_DUPLICATE_QUERIES must be 'yes' or 'no', got: '$DISPATCHER_ALLOW_DUPLICATE_QUERIES'"
  usage
  exit 1
fi

LOGROTATE_AVAILABLE=false
if command -v logrotate > /dev/null 2>&1; then
  LOGROTATE_AVAILABLE=true
else
  message "WARNING: logrotate not found, log files will not be rotated"
fi

# ============================================================================
# DATABASE STATE DETECTION
# ============================================================================

# Detect the meta mode of the database by checking for characteristic files
# Returns: "no", "yes", or "attic" via stdout
# Returns 1 if base files are missing (database not initialized)
detect_database_meta_state()
{
  # Check for attic files (most specific check first)
  if [[ -f "$OVERPASS_DB_DIR/nodes_attic.bin" && -f "$OVERPASS_DB_DIR/node_changelog.bin" && -f "$OVERPASS_DB_DIR/ways_attic.bin" ]]; then
    echo "attic"
    return 0
  fi

  # Check for meta files
  if [[ -f "$OVERPASS_DB_DIR/nodes_meta.bin" && -f "$OVERPASS_DB_DIR/ways_meta.bin" && -f "$OVERPASS_DB_DIR/user_data.bin" ]]; then
    echo "yes"
    return 0
  fi

  # No meta or attic files found - verify base files exist
  if [[ ! -f "$OVERPASS_DB_DIR/nodes.bin" || ! -f "$OVERPASS_DB_DIR/ways.bin" || ! -f "$OVERPASS_DB_DIR/relations.bin" ]]; then
    return 1
  fi

  echo "no"
  return 0
}

# Validate that user-specified meta mode matches database state
validate_meta_mode()
{
  # Detect actual database state
  local DB_STATE
  DB_STATE=$(detect_database_meta_state)
  if [[ $? -ne 0 ]]; then
    message "ERROR: Database directory does not contain required base files (nodes.bin, ways.bin, relations.bin)"
    message "The database may not be properly initialized"
    message "See README.md for initialization instructions"
    exit 1
  fi

  # Compare user mode with database state
  if [[ "$OVERPASS_META_MODE" != "$DB_STATE" ]]; then
    message "ERROR: Meta mode mismatch. Argument: --meta=$OVERPASS_META_MODE; Database: --meta=$DB_STATE"
    exit 1
  fi
}

# ============================================================================
# STARTUP
# ============================================================================

start_base_dispatcher()
{
  message "Starting base dispatcher"
  local META_FLAG=()
  if [[ $OVERPASS_META_MODE == "yes" ]]; then
    META_FLAG=(--meta)
  elif [[ $OVERPASS_META_MODE == "attic" ]]; then
    META_FLAG=(--attic)
  fi

  "$EXEC_DIR/dispatcher" --osm-base \
    "${META_FLAG[@]}" \
    --db-dir="$OVERPASS_DB_DIR" \
    --socket-dir="$OVERPASS_SOCKET_DIR" \
    --space="$DISPATCHER_BASE_SPACE" \
    --time="$DISPATCHER_TIME" \
    --rate-limit="$DISPATCHER_RATE_LIMIT" \
    --allow-duplicate-queries="$DISPATCHER_ALLOW_DUPLICATE_QUERIES" \
    >> "$OVERPASS_DB_DIR/base_dispatcher.out" 2>&1 \
    &
  DISPATCHER_BASE_PID=$!
  sleep_with_interrupts 1
  message "Started base dispatcher (PID $DISPATCHER_BASE_PID)"
}

start_areas_dispatcher()
{
  if [[ $AREAS == "yes" ]]; then
    message "Starting areas dispatcher"
    "$EXEC_DIR/dispatcher" --areas \
      --db-dir="$OVERPASS_DB_DIR" \
      --socket-dir="$OVERPASS_SOCKET_DIR" \
      --space="$DISPATCHER_AREAS_SPACE" \
      --time="$DISPATCHER_TIME" \
      --rate-limit="$DISPATCHER_RATE_LIMIT" \
      --allow-duplicate-queries="$DISPATCHER_ALLOW_DUPLICATE_QUERIES" \
      >> "$OVERPASS_DB_DIR/areas_dispatcher.out" 2>&1 \
      &
    DISPATCHER_AREAS_PID=$!
    sleep_with_interrupts 1
    message "Started areas dispatcher  (PID $DISPATCHER_AREAS_PID)"
  else
    message "Skipping area dispatcher startup (--areas=$AREAS)"
    DISPATCHER_AREAS_PID=
  fi
}

start_apply_osc()
{
  message "Starting apply_osc_to_db.sh"
  "$EXEC_DIR/apply_osc_to_db.sh" \
    "$OVERPASS_DIFF_DIR" \
    "$START_ID" \
    --meta="$OVERPASS_META_MODE" \
    >> "$OVERPASS_DB_DIR/apply_osc_to_db.out" 2>&1 \
    &
  APPLY_OSC_PID=$!
  sleep_with_interrupts 1
  message "Started apply_osc_to_db.sh (PID $APPLY_OSC_PID)"
}

start_fetch_osc()
{
  message "Starting fetch_osc.sh"
  local FETCH_START_ID
  if [[ "$START_ID" == "auto" ]]; then
    FETCH_START_ID="auto"
  else
    FETCH_START_ID=$((START_ID + 1))
  fi

  "$EXEC_DIR/fetch_osc.sh" \
    "$FETCH_START_ID" \
    "$OVERPASS_DIFF_URL" \
    "$OVERPASS_DIFF_DIR" \
    >> "$OVERPASS_DIFF_DIR/fetch_osc.out" 2>&1 \
    &
  FETCH_OSC_PID=$!
  sleep_with_interrupts 1
  message "Started fetch_osc.sh (PID $FETCH_OSC_PID)"
}

start_rules_loop()
{
  if [[ "$AREAS" == "yes" ]]; then
    message "Starting rules_loop.sh"
    "$EXEC_DIR/rules_loop.sh" \
      >> "$OVERPASS_DB_DIR/rules_loop.out" 2>&1 \
      &
    RULES_LOOP_PID=$!
    sleep_with_interrupts 1
    message "Started rules_loop.sh (PID $RULES_LOOP_PID)"
  else
    message "Skipping rules_loop.sh startup (--areas=$AREAS)"
    RULES_LOOP_PID=
  fi
}

start_backup()
{
  if [[ "$BACKUP" == "yes" ]]; then
    message "Starting backup.sh"
    "$EXEC_DIR/backup.sh" \
      "$OVERPASS_BACKUP_DIR" \
      >> "$OVERPASS_DB_DIR/backup.out" 2>&1 \
      &
    BACKUP_PID=$!
    sleep_with_interrupts 1
    message "Started backup.sh (PID $BACKUP_PID)"
  else
    message "Skipping backup.sh startup (set OVERPASS_BACKUP_* environment variables to enable backup)"
  fi
}

# ============================================================================
# SHUTDOWN
# ============================================================================

kill_child()
{
  local CHILD_NAME="$1"
  local CHILD_PID="$2"

  kill "$CHILD_PID" 2>/dev/null
  local WAIT_COUNT=0
  while kill -0 "$CHILD_PID" 2>/dev/null && [[ $WAIT_COUNT -lt 30 ]]; do
    sleep 1
    ((++WAIT_COUNT))
  done
  if kill -0 "$CHILD_PID" 2>/dev/null; then
    message "ERROR: Unable to forcefully terminate $CHILD_NAME, killing"
    kill -9 "$CHILD_PID" 2>/dev/null
  fi
  wait "$CHILD_PID" 2>/dev/null
}

stop_base_dispatcher()
{
  if [[ -n "$DISPATCHER_BASE_PID" ]] && kill -0 "$DISPATCHER_BASE_PID" 2>/dev/null; then
    message "Stopping base dispatcher"
    if "$EXEC_DIR/dispatcher" --osm-base --terminate; then
      wait "$DISPATCHER_BASE_PID"
    else
      message "ERROR: Unable to safely terminate base dispatcher"
      message "Attempting to forcefully terminate base dispatcher"
      kill_child "base dispatcher" "$DISPATCHER_BASE_PID"
    fi
    message "Stopped base dispatcher"
  fi
  DISPATCHER_BASE_PID=
}

stop_areas_dispatcher()
{
  if [[ -n "$DISPATCHER_AREAS_PID" ]] && kill -0 "$DISPATCHER_AREAS_PID" 2>/dev/null; then
    message "Stopping areas dispatcher"
    if "$EXEC_DIR/dispatcher" --areas --terminate; then
      wait "$DISPATCHER_AREAS_PID"
    else
      message "ERROR: Unable to safely terminate areas dispatcher"
      message "Attempting to forcefully terminate areas dispatcher"
      kill_child "areas dispatcher" "$DISPATCHER_AREAS_PID"
    fi
    message "Stopped areas dispatcher"
  fi
  DISPATCHER_AREAS_PID=
}

stop_apply_osc()
{
  if [[ -n "$APPLY_OSC_PID" ]] && kill -0 "$APPLY_OSC_PID" 2>/dev/null; then
    message "Stopping apply_osc_to_db.sh (attempting safe termination)"
    message "This may take some time while we wait for updates to finish"
    kill "$APPLY_OSC_PID" 2>/dev/null
    wait "$APPLY_OSC_PID"
    message "Stopped apply_osc_to_db.sh"
  fi
  APPLY_OSC_PID=
}

stop_fetch_osc()
{
  if [[ -n "$FETCH_OSC_PID" ]] && kill -0 "$FETCH_OSC_PID" 2>/dev/null; then
    message "Stopping fetch_osc.sh"
    kill "$FETCH_OSC_PID" 2>/dev/null
    wait "$FETCH_OSC_PID"
    message "Stopped fetch_osc.sh"
  fi
  FETCH_OSC_PID=
}

stop_rules_loop()
{
  if [[ -n "$RULES_LOOP_PID" ]] && kill -0 "$RULES_LOOP_PID" 2>/dev/null; then
    message "Stopping rules_loop.sh"
    kill "$RULES_LOOP_PID" 2>/dev/null
    wait "$RULES_LOOP_PID"
    message "Stopped rules_loop.sh"
  fi
  RULES_LOOP_PID=
}

stop_backup()
{
  if [[ -n "$BACKUP_PID" ]] && kill -0 "$BACKUP_PID" 2>/dev/null; then
    message "Stopping backup.sh"
    kill "$BACKUP_PID" 2>/dev/null
    wait "$BACKUP_PID"
    message "Stopped backup.sh"
  fi
  BACKUP_PID=
}

stop_overpass()
{
  stop_backup
  stop_rules_loop
  stop_fetch_osc
  stop_apply_osc
  stop_areas_dispatcher
  stop_base_dispatcher
}

# ============================================================================
# HEALTH CHECKS
# ============================================================================

check_base_dispatcher()
{
  local DB_DIR
  local EXIT_CODE
  DB_DIR=$("$EXEC_DIR/dispatcher" --show-dir)
  EXIT_CODE=$?
  DB_DIR="${DB_DIR%/}"
  if [[ "$EXIT_CODE" -ne 0 || "$DB_DIR" != "$OVERPASS_DB_DIR" ]]; then
    return 1
  fi
  return 0
}

check_areas_dispatcher()
{
  [[ "$AREAS" == "no" ]] && return 0
  local DB_DIR
  local EXIT_CODE
  DB_DIR=$("$EXEC_DIR/dispatcher" --areas --show-dir)
  EXIT_CODE=$?
  DB_DIR="${DB_DIR%/}"
  if [[ "$EXIT_CODE" -ne 0 || "$DB_DIR" != "$OVERPASS_DB_DIR" ]]; then
    return 1
  fi
  return 0
}

check_apply_osc()
{
  if [[ -n "$APPLY_OSC_PID" ]] && kill -0 "$APPLY_OSC_PID" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

check_fetch_osc()
{
  if [[ -n "$FETCH_OSC_PID" ]] && kill -0 "$FETCH_OSC_PID" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

check_rules_loop()
{
  [[ "$AREAS" == "no" ]] && return 0
  if [[ -n "$RULES_LOOP_PID" ]] && kill -0 "$RULES_LOOP_PID" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

check_backup()
{
  [[ "$BACKUP" == "no" ]] && return 0
  if [[ -n "$BACKUP_PID" ]] && kill -0 "$BACKUP_PID" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

check_overpass()
{
  if check_backup && check_rules_loop && \
    check_fetch_osc && check_apply_osc && \
    check_areas_dispatcher && check_base_dispatcher; then
    return 0
  fi
  return 1
}

check_lock_files()
{
  local LOCK_FILES=("$OVERPASS_DB_DIR/osm_base_shadow.lock")
  if [[ "$AREAS" == "yes" ]]; then
    LOCK_FILES+=("$OVERPASS_DB_DIR/areas_shadow.lock")
  fi

  local LOCK_FILE PID MTIME
  for LOCK_FILE in "${LOCK_FILES[@]}"; do
    [[ -f "$LOCK_FILE" ]] || continue

    PID=$(< "$LOCK_FILE")
    if [[ "$PID" =~ ^[1-9][0-9]*$ ]] && kill -0 "$PID" 2>/dev/null; then
      if [[ "$(readlink "/proc/$PID/exe" 2>/dev/null)" == "$EXEC_DIR/"* ]]; then
        continue
      fi
    fi

    # PID is absent, dead, or not an Overpass process - wait and recheck
    MTIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null) || continue
    sleep_with_interrupts 5
    [[ -f "$LOCK_FILE" ]] || continue
    [[ "$(stat -c %Y "$LOCK_FILE" 2>/dev/null)" == "$MTIME" ]] || continue

    PID=$(< "$LOCK_FILE")
    if [[ "$PID" =~ ^[1-9][0-9]*$ ]] && kill -0 "$PID" 2>/dev/null; then
      if [[ "$(readlink "/proc/$PID/exe" 2>/dev/null)" == "$EXEC_DIR/"* ]]; then
        continue
      fi
    fi

    message "ERROR: Orphaned lock file detected: $LOCK_FILE (PID: $PID)"
    return 1
  done

  return 0
}

# ============================================================================
# LOG ROTATION
# ============================================================================

generate_logrotate_config()
{
  cat > "$OVERPASS_DB_DIR/logrotate.conf" <<EOF
$OVERPASS_DB_DIR/*.log $OVERPASS_DB_DIR/*.out $OVERPASS_DIFF_DIR/*.log $OVERPASS_DIFF_DIR/*.out {
    daily
    missingok
    copytruncate
    rotate 3
    compress
    delaycompress
    notifempty
}
EOF

  if [[ -n "$OVERPASS_LOG_DIR" ]]; then
    cat >> "$OVERPASS_DB_DIR/logrotate.conf" <<EOF
$OVERPASS_LOG_DIR/*.log {
    daily
    missingok
    copytruncate
    rotate 3
    compress
    delaycompress
    notifempty
}
EOF
  fi
}

# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

shutdown()
{
  local EXIT_CODE=$1
  message "Shutdown signal received, cleaning up..."

  stop_overpass

  message "Shutdown complete"
  exit "$EXIT_CODE"
}

trap 'shutdown 143' SIGTERM
trap 'shutdown 130' SIGINT
trap 'shutdown 129' SIGHUP

# ============================================================================
# MAIN EXECUTION
# ============================================================================

message "-----------------------------------"
message "Starting Overpass ($0)"
message "-----------------------------------"
message "OVERPASS_REPLICATE_ID              $START_ID"
message "OVERPASS_DB_DIR                    $OVERPASS_DB_DIR"
message "OVERPASS_DIFF_DIR                  $OVERPASS_DIFF_DIR"
message "OVERPASS_DIFF_URL                  $OVERPASS_DIFF_URL"
message "OVERPASS_META_MODE                 $OVERPASS_META_MODE"
message "OVERPASS_AREAS                     $AREAS"
message "OVERPASS_UPDATE_FREQUENCY          $OVERPASS_UPDATE_FREQUENCY seconds"
message "OVERPASS_SOCKET_DIR                $OVERPASS_SOCKET_DIR"
message "OVERPASS_STALL_MULTIPLIER          $OVERPASS_STALL_MULTIPLIER"
message "OVERPASS_CLEANUP_INTERVAL          $OVERPASS_CLEANUP_INTERVAL hours"
message "OVERPASS_CLEANUP_KEEP_HOURS        $OVERPASS_CLEANUP_KEEP_HOURS hours"
message "DISPATCHER_BASE_SPACE              ~$((DISPATCHER_BASE_SPACE / 1048576)) MiB"
message "DISPATCHER_AREAS_SPACE             ~$((DISPATCHER_AREAS_SPACE / 1048576)) MiB"
message "DISPATCHER_TIME                    $DISPATCHER_TIME seconds"
message "DISPATCHER_RATE_LIMIT              $DISPATCHER_RATE_LIMIT"
message "DISPATCHER_ALLOW_DUPLICATE_QUERIES $DISPATCHER_ALLOW_DUPLICATE_QUERIES"
message "-----------------------------------"

validate_meta_mode

generate_logrotate_config

start_base_dispatcher

if ! check_base_dispatcher; then
  message "ERROR: Unable to start base dispatcher"
  stop_overpass
  exit 1
fi

start_areas_dispatcher

if ! check_areas_dispatcher; then
  message "ERROR: Unable to start areas dispatcher"
  stop_overpass
  exit 1
fi

start_apply_osc

if ! check_apply_osc; then
  message "ERROR: Unable to start apply_osc_to_db.sh"
  stop_overpass
  exit 1
fi

start_fetch_osc

if ! check_fetch_osc; then
  message "ERROR: Unable to start fetch_osc.sh"
  stop_overpass
  exit 1
fi

start_rules_loop

if ! check_rules_loop; then
  message "ERROR: Unable to start rules_loop.sh"
  stop_overpass
  exit 1
fi

start_backup

if ! check_backup; then
  message "ERROR: Unable to start backup.sh"
  stop_overpass
  exit 1
fi

message "Checking startup ..."
if check_overpass; then
  message "Startup complete"
else
  message "ERROR: Startup failed, shutting down"
  stop_overpass
  exit 1
fi

# ============================================================================
# MAIN LOOP
# ============================================================================

NOW=$(date +%s)
LAST_HEALTH_MESSAGE="$NOW"
LAST_CLEANUP="$NOW"
if [[ -n "$OVERPASS_STALL_MULTIPLIER" ]]; then
  STALL_DETECTION="yes"
  STALL_THRESHOLD=$(( OVERPASS_UPDATE_FREQUENCY * OVERPASS_STALL_MULTIPLIER ))
else
  STALL_DETECTION="no"
fi
CLEANUP_THRESHOLD=$(( OVERPASS_CLEANUP_INTERVAL * 3600 ))
CLEANUP_KEEP_COUNT=$(( OVERPASS_CLEANUP_KEEP_HOURS * 3600 / OVERPASS_UPDATE_FREQUENCY ))
SLEEP_TIME="$OVERPASS_UPDATE_FREQUENCY"

while true; do
  sleep_with_interrupts "$SLEEP_TIME"

  NOW=$(date +%s)

  if ! check_overpass; then
    message "ERROR: Health check failed, shutting down"
    stop_overpass
    exit 1
  fi

  if ! check_lock_files; then
    message "WARNING: A database write may have failed; database may be corrupted"
  fi

  REPLICATE_ID_TIMESTAMP=$(stat -c %Y "$OVERPASS_DB_DIR/replicate_id" 2>/dev/null)
  if [[ -n "$REPLICATE_ID_TIMESTAMP" ]]; then
    if [[ "$STALL_DETECTION" == "yes" ]] && (( NOW - REPLICATE_ID_TIMESTAMP > STALL_THRESHOLD )); then
      message "WARNING: Database has not advanced in $(( NOW - REPLICATE_ID_TIMESTAMP ))s (threshold: ${STALL_THRESHOLD}s)"
    fi
  fi

  if (( NOW - LAST_HEALTH_MESSAGE >= 3600)); then
    message "Overpass processes are running and database has been recently updated"
    LAST_HEALTH_MESSAGE="$NOW"
  fi

  if (( NOW - LAST_CLEANUP > CLEANUP_THRESHOLD )); then
    message "Running periodic diff cleanup"
    "$EXEC_DIR/clean_osc.sh" "$OVERPASS_DB_DIR" "$OVERPASS_DIFF_DIR" "$CLEANUP_KEEP_COUNT" \
      >> "$OVERPASS_DIFF_DIR/clean_osc.out" 2>&1
    LAST_CLEANUP=$NOW
  fi
  
  if [[ "$LOGROTATE_AVAILABLE" == "true" ]]; then
    logrotate --state "$OVERPASS_DB_DIR/logrotate.status" \
      "$OVERPASS_DB_DIR/logrotate.conf" \
      >> "$OVERPASS_DB_DIR/logrotate.out" 2>&1
  fi

  SLEEP_TIME=$(( OVERPASS_UPDATE_FREQUENCY - $(date +%s) + NOW ))
  (( SLEEP_TIME < 0 )) && SLEEP_TIME=$(( (SLEEP_TIME % OVERPASS_UPDATE_FREQUENCY) + OVERPASS_UPDATE_FREQUENCY ))
done
