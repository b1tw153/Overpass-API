#!/bin/bash

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
    --replicate-dir=OVERPASS_DIFF_DIR
    --source-url=FETCH_OSC_SOURCE
    --meta=no|yes|attic
    --areas=no|yes

--run=REPLICATE_ID
    The replicate ID to start fetching diffs from.

--db-dir=DB_DIR
    The directory where the database is stored.

--replicate-dir=OVERPASS_DIFF_DIR
    The directory where the diffs are stored.

--source-url=FETCH_OSC_SOURCE
    Specify the URL to download the diffs from. The usual URL is
    https://planet.openstreetmap.org/replication/minute/

--meta=attic|yes|no
    Keep or discard meta/attic data in the database.

--areas=yes|no
    Create or skip derived area data.
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

# ============================================================================
# ARGUMENT PARAMETERS
# ============================================================================

PARSED=$(getopt \
  --options '' \
  --longoptions 'run:,db-dir:,replicate-dir:,source-url:,meta:,areas:,help' \
  --name "$0" \
  -- "$@") || { usage; exit 1; }

eval set -- "$PARSED"

START_ID="${OVERPASS_REPLICATE_ID:-}"
OVERPASS_DB_DIR="${OVERPASS_DB_DIR:-}"
OVERPASS_DIFF_DIR="${OVERPASS_DIFF_DIR:-}"
FETCH_OSC_SOURCE="${FETCH_OSC_SOURCE:-}"
OVERPASS_META_MODE="${OVERPASS_META_MODE:-}"
AREAS="${OVERPASS_AREAS:-}"

while true; do
  case "$1" in
    --run)           START_ID="$2";           shift 2 ;;
    --db-dir)        OVERPASS_DB_DIR="$2";    shift 2 ;;
    --replicate-dir) OVERPASS_DIFF_DIR="$2";  shift 2 ;;
    --source-url)    FETCH_OSC_SOURCE="$2";   shift 2 ;;
    --meta)          OVERPASS_META_MODE="$2"; shift 2 ;;
    --areas)         AREAS="$2";              shift 2 ;;
    --help)          print_help;              exit  0 ;;
    --)              shift; break ;;
  esac
done

if [[ -z $START_ID ]]; then
  echo "Error: --run is required"
  exit 1
fi

if [[ "$START_ID" != "auto" && ! "$START_ID" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: Invalid --run value '$START_ID': must be a positive integer or 'auto'"
  exit 1
fi

if [[ -z $OVERPASS_DB_DIR ]]; then
  echo "Error: --db-dir is required"
  exit 1
fi

if ! [[ -d $OVERPASS_DB_DIR && -w $OVERPASS_DB_DIR ]]; then
  echo "ERROR: --db-dir '$OVERPASS_DB_DIR' is not a writeable directory"
  exit 1
fi
    
if [[ -z $OVERPASS_DIFF_DIR ]]; then
  echo "Error: --replicate-dir is required"
  exit 1
fi

if ! [[ -d "$OVERPASS_DIFF_DIR" && -w "$OVERPASS_DIFF_DIR" ]]; then
  echo "ERROR: --replicate-dir '$OVERPASS_DIFF_DIR' is not a writeable directory"
  exit 1
fi

if [[ -z $FETCH_OSC_SOURCE ]]; then
  echo "Error: --source-url is required"
  exit 1
fi

if [[ ! "$FETCH_OSC_SOURCE" =~ ^https?:// ]]; then
  echo "ERROR: Invalid FETCH_OSC_SOURCE '$FETCH_OSC_SOURCE': must start with http:// or https://"
  exit 1
fi

if [[ $OVERPASS_META_MODE != "attic" && $OVERPASS_META_MODE != "yes" && $OVERPASS_META_MODE != "no" ]]; then
  echo "Error: --meta must be 'attic', 'yes', or 'no'"
  exit 1
fi

if [[ $AREAS != "yes" && $AREAS != "no" ]]; then
  echo "Error: --areas must be 'yes' or 'no'"
  exit 1
fi

# Get execution directory
EXEC_DIR="$(dirname "$0")/"
if [[ ! ${EXEC_DIR:0:1} == "/" ]]; then
  EXEC_DIR="$(pwd)/$EXEC_DIR"
fi

# Convert replicate-dir to absolute path
if [[ ! ${OVERPASS_DIFF_DIR:0:1} == "/" ]]; then
  OVERPASS_DIFF_DIR="$(pwd)/$OVERPASS_DIFF_DIR"
fi

# Convert db-dir to absolute path
if [[ ! ${OVERPASS_DB_DIR:0:1} == "/" ]]; then
  OVERPASS_DB_DIR="$(pwd)/$OVERPASS_DB_DIR"
fi

# ============================================================================
# ENVIRONMENT VARIABLE PARAMETERS
# ============================================================================

OVERPASS_UPDATE_FREQUENCY=${OVERPASS_UPDATE_FREQUENCY:-60}
OVERPASS_SOCKET_DIR=${OVERPASS_SOCKET_DIR:-"$OVERPASS_DB_DIR"}
OVERPASS_STALL_MULTIPLIER=${OVERPASS_STALL_MULTIPLIER:-5}
OVERPASS_CLEANUP_MULTIPLIER=${OVERPASS_CLEANUP_MULTIPLIER:-1440}
DISPATCHER_BASE_SPACE=${DISPATCHER_BASE_SPACE:-12884901888}
DISPATCHER_AREAS_SPACE=${DISPATCHER_AREAS_SPACE:-4294967296}
DISPATCHER_TIME=${DISPATCHER_TIME:-262144}
DISPATCHER_RATE_LIMIT=${DISPATCHER_RATE_LIMIT:-0}
DISPATCHER_ALLOW_DUPLICATE_QUERIES=${DISPATCHER_ALLOW_DUPLICATE_QUERIES:-yes}

if ! [[ -d "$OVERPASS_SOCKET_DIR" && -w "$OVERPASS_SOCKET_DIR" ]]; then
  echo "ERROR: OVERPASS_SOCKET_DIR '$OVERPASS_SOCKET_DIR' is not a writeable directory"
  exit 1
fi

if [[ ! "$DISPATCHER_BASE_SPACE" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: DISPATCHER_BASE_SPACE must be a positive integer, got: '$DISPATCHER_BASE_SPACE'"
  exit 1
fi

if [[ ! "$DISPATCHER_AREAS_SPACE" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: DISPATCHER_AREAS_SPACE must be a positive integer, got: '$DISPATCHER_AREAS_SPACE'"
  exit 1
fi

if [[ ! "$DISPATCHER_TIME" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: DISPATCHER_TIME must be a positive integer, got: '$DISPATCHER_TIME'"
  exit 1
fi

if [[ ! "$DISPATCHER_RATE_LIMIT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: DISPATCHER_RATE_LIMIT must be a non-negative integer, got: '$DISPATCHER_RATE_LIMIT'"
  exit 1
fi

if [[ "$DISPATCHER_ALLOW_DUPLICATE_QUERIES" != "yes" && "$DISPATCHER_ALLOW_DUPLICATE_QUERIES" != "no" ]]; then
  echo "ERROR: DISPATCHER_ALLOW_DUPLICATE_QUERIES must be 'yes' or 'no', got: '$DISPATCHER_ALLOW_DUPLICATE_QUERIES'"
  exit 1
fi

if [[ ! "$OVERPASS_UPDATE_FREQUENCY" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: OVERPASS_UPDATE_FREQUENCY must be a positive integer, got: '$OVERPASS_UPDATE_FREQUENCY'"
  exit 1
fi

if [[ "$OVERPASS_UPDATE_FREQUENCY" -ne 60 && "$OVERPASS_UPDATE_FREQUENCY" -ne 3600 && "$OVERPASS_UPDATE_FREQUENCY" -ne 86400 ]]; then
  echo "WARNING: Unexpected OVERPASS_UPDATE_FREQUENCY: $OVERPASS_UPDATE_FREQUENCY (expected: 60, 3600, 86400)"
fi

if [[ ! "$OVERPASS_STALL_MULTIPLIER" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: OVERPASS_STALL_MULTIPLIER must be a positive integer, got: '$OVERPASS_STALL_MULTIPLIER'"
  exit 1
fi

if [[ ! "$OVERPASS_CLEANUP_MULTIPLIER" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: OVERPASS_CLEANUP_MULTIPLIER must be a positive integer, got: '$OVERPASS_CLEANUP_MULTIPLIER'"
  exit 1
fi

LOGROTATE_AVAILABLE=false
if command -v logrotate > /dev/null 2>&1; then
  LOGROTATE_AVAILABLE=true
else
  echo "WARNING: logrotate not found, log files will not be rotated"
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
    echo "ERROR: Database directory does not contain required base files (nodes.bin, ways.bin, relations.bin)"
    echo "The database may not be properly initialized"
    echo "Run ... TBD ... to initialize the database"
    exit 1
  fi

  # Compare user mode with database state
  if [[ "$OVERPASS_META_MODE" != "$DB_STATE" ]]; then
    echo "ERROR: Meta mode mismatch. Argument: --meta=$OVERPASS_META_MODE; Database: --meta=$DB_STATE"
    exit 1
  fi
}

# ============================================================================
# STARTUP
# ============================================================================

start_base_dispatcher()
{
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
}

start_areas_dispatcher()
{
  if [[ $AREAS == "yes" ]]; then
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
  else
    DISPATCHER_AREAS_PID=
  fi
}

start_apply_osc()
{
  "$EXEC_DIR/apply_osc_to_db.sh" \
    "$OVERPASS_DIFF_DIR" \
    "$START_ID" \
    --meta="$OVERPASS_META_MODE" \
    >> "$OVERPASS_DB_DIR/apply_osc_to_db.out" 2>&1 \
    &
  APPLY_OSC_PID=$!
  sleep_with_interrupts 1
}

start_fetch_osc()
{
  local FETCH_START_ID
  if [[ "$START_ID" == "auto" ]]; then
    FETCH_START_ID="auto"
  else
    FETCH_START_ID=$((START_ID + 1))
  fi

  "$EXEC_DIR/fetch_osc.sh" \
    "$FETCH_START_ID" \
    "$FETCH_OSC_SOURCE" \
    "$OVERPASS_DIFF_DIR" \
    >> "$OVERPASS_DIFF_DIR/fetch_osc.out" 2>&1 \
    &
  FETCH_OSC_PID=$!
  sleep_with_interrupts 1
}

start_rules_loop()
{
  if [[ "$AREAS" == "yes" ]]; then
    "$EXEC_DIR/rules_loop.sh" \
      "$OVERPASS_DB_DIR" \
      >> "$OVERPASS_DB_DIR/rules_loop.out" 2>&1 \
      &
    RULES_LOOP_PID=$!
    sleep_with_interrupts 1
  else
    RULES_LOOP_PID=
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
    echo "ERROR: Unable to forcefully terminate $CHILD_NAME, killing"
    kill -9 "$CHILD_PID" 2>/dev/null
  fi
  wait "$CHILD_PID" 2>/dev/null
}

stop_base_dispatcher()
{
  if [[ -n "$DISPATCHER_BASE_PID" ]] && kill -0 "$DISPATCHER_BASE_PID" 2>/dev/null; then
    if "$EXEC_DIR/dispatcher" --osm-base --terminate; then
      wait "$DISPATCHER_BASE_PID"
    else
      echo "ERROR: Unable to safely terminate base dispatcher"
      echo "Attempting to forcefully terminate base dispatcher"
      kill_child "base dispatcher" "$DISPATCHER_BASE_PID"
    fi
  fi
  DISPATCHER_BASE_PID=
}

stop_areas_dispatcher()
{
  if [[ -n "$DISPATCHER_AREAS_PID" ]] && kill -0 "$DISPATCHER_AREAS_PID" 2>/dev/null; then
    if "$EXEC_DIR/dispatcher" --areas --terminate; then
      wait "$DISPATCHER_AREAS_PID"
    else
      echo "ERROR: Unable to safely terminate areas dispatcher"
      echo "Attempting to forcefully terminate areas dispatcher"
      kill_child "areas dispatcher" "$DISPATCHER_AREAS_PID"
    fi
  fi
  DISPATCHER_AREAS_PID=
}

stop_apply_osc()
{
  if [[ -n "$APPLY_OSC_PID" ]] && kill -0 "$APPLY_OSC_PID" 2>/dev/null; then
    echo "Attempting to safely terminate apply_osc_to_db.sh"
    echo "This may take some time while we wait for updates to finish"
    kill "$APPLY_OSC_PID" 2>/dev/null
    wait "$APPLY_OSC_PID"
  fi
  APPLY_OSC_PID=
}

stop_fetch_osc()
{
  if [[ -n "$FETCH_OSC_PID" ]] && kill -0 "$FETCH_OSC_PID" 2>/dev/null; then
    kill "$FETCH_OSC_PID" 2>/dev/null
    wait "$FETCH_OSC_PID"
  fi
  FETCH_OSC_PID=
}

stop_rules_loop()
{
  if [[ -n "$RULES_LOOP_PID" ]] && kill -0 "$RULES_LOOP_PID" 2>/dev/null; then
    kill "$RULES_LOOP_PID" 2>/dev/null
    wait "$RULES_LOOP_PID"
  fi
  RULES_LOOP_PID=
}

stop_overpass()
{
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

check_overpass()
{
  if check_rules_loop && check_fetch_osc && check_apply_osc && \
     check_areas_dispatcher && check_base_dispatcher; then
    return 0
  fi
  return 1
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
}

# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

shutdown()
{
  local EXIT_CODE=$1
  echo "Shutdown signal received, cleaning up..."

  stop_overpass

  echo "Shutdown complete"
  exit "$EXIT_CODE"
}

trap 'shutdown 143' SIGTERM
trap 'shutdown 130' SIGINT
trap 'shutdown 129' SIGHUP

# ============================================================================
# MAIN EXECUTION
# ============================================================================

validate_meta_mode

generate_logrotate_config

start_base_dispatcher

if ! check_base_dispatcher; then
  echo "ERROR: Unable to start base dispatcher"
  stop_overpass
  exit 1
fi

start_areas_dispatcher

if ! check_areas_dispatcher; then
  echo "ERROR: Unable to start areas dispatcher"
  stop_overpass
  exit 1
fi

start_apply_osc

if ! check_apply_osc; then
  echo "ERROR: Unable to start apply_osc_to_db.sh"
  stop_overpass
  exit 1
fi

start_fetch_osc

if ! check_fetch_osc; then
  echo "ERROR: Unable to start fetch_osc.sh"
  stop_overpass
  exit 1
fi

start_rules_loop

if ! check_rules_loop; then
  echo "ERROR: Unable to start rules_loop.sh"
  stop_overpass
  exit 1
fi

echo "Checking startup ..."
if check_overpass; then
  echo "Startup complete"
else
  echo "ERROR: Startup failed, shutting down"
  stop_overpass
  exit 1
fi

# ============================================================================
# MAIN LOOP
# ============================================================================

LAST_CLEANUP=$(date +%s)
STALL_THRESHOLD=$(( OVERPASS_UPDATE_FREQUENCY * OVERPASS_STALL_MULTIPLIER ))
CLEANUP_THRESHOLD=$(( OVERPASS_UPDATE_FREQUENCY * OVERPASS_CLEANUP_MULTIPLIER ))
SLEEP_TIME="$OVERPASS_UPDATE_FREQUENCY"

while true; do
  sleep_with_interrupts "$SLEEP_TIME"

  NOW=$(date +%s)

  if ! check_overpass; then
    echo "ERROR: Health check failed, shutting down"
    stop_overpass
    exit 1
  fi

  REPLICATE_ID_TIMESTAMP=$(stat -c %Y "$OVERPASS_DB_DIR/replicate_id" 2>/dev/null)
  if [[ -n "$REPLICATE_ID_TIMESTAMP" ]]; then
    if (( NOW - REPLICATE_ID_TIMESTAMP > STALL_THRESHOLD )); then
      echo "ERROR: Database has not advanced in $(( NOW - REPLICATE_ID_TIMESTAMP ))s (threshold: ${STALL_THRESHOLD}s), shutting down"
      stop_overpass
      exit 1
    fi
  fi

  if (( NOW - LAST_CLEANUP > CLEANUP_THRESHOLD )); then
    echo "Running periodic diff cleanup"
    "$EXEC_DIR/clean_osc.sh" "$OVERPASS_DB_DIR" "$OVERPASS_DIFF_DIR" \
      >> "$OVERPASS_DIFF_DIR/clean_osc.out" 2>&1
    if [[ "$LOGROTATE_AVAILABLE" == "true" ]]; then
      logrotate --state "$OVERPASS_DB_DIR/logrotate.status" \
        -f "$OVERPASS_DB_DIR/logrotate.conf" \
        >> "$OVERPASS_DB_DIR/logrotate.out" 2>&1
    fi
    LAST_CLEANUP=$NOW
  fi
  
  WAKE_TIME=$(( $(date +%s) - NOW ))
  SLEEP_TIME=$(( OVERPASS_UPDATE_FREQUENCY - WAKE_TIME ))
  (( SLEEP_TIME < 0 )) && SLEEP_TIME=0
done
