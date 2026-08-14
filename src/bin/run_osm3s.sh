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
  OVERPASS_MIN_FREE_DISK_PERCENT
                                Minimum free disk space on the log filesystem as a percentage;
                                Overpass shuts down if the threshold is not met (default: 5)
  DISPATCHER_BASE_SPACE         Base dispatcher shared memory in bytes (default: 12884901888)
  DISPATCHER_AREAS_SPACE        Areas dispatcher shared memory in bytes (default: DISPATCHER_BASE_SPACE)
  DISPATCHER_BASE_TIME          Base dispatcher time limit (default: 262144)
  DISPATCHER_AREAS_TIME         Areas dispatcher time limit (default: DISPATCHER_BASE_TIME)
  DISPATCHER_RATE_LIMIT         Dispatcher rate limit; 0 means unlimited (default: 0)
  DISPATCHER_ALLOW_DUPLICATE_QUERIES
                                Allow duplicate queries: yes|no (default: yes)
  DISPATCHER_LIMIT_CLIENT_ZERO  Apply rate limit to local queries: yes|no (default: no)

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

EXEC_DIR="$(dirname "$(realpath "$0")")"
OVERPASS_DIFF_DIR="$(realpath "$OVERPASS_DIFF_DIR")"
OVERPASS_DB_DIR="$(realpath "$OVERPASS_DB_DIR")"

# ============================================================================
# ENVIRONMENT VARIABLE PARAMETERS
# ============================================================================

OVERPASS_SOCKET_DIR=${OVERPASS_SOCKET_DIR:-"$OVERPASS_DB_DIR"}
OVERPASS_STALL_MULTIPLIER=${OVERPASS_STALL_MULTIPLIER:-}
OVERPASS_CLEANUP_INTERVAL=${OVERPASS_CLEANUP_INTERVAL:-24}
OVERPASS_CLEANUP_KEEP_HOURS=${OVERPASS_CLEANUP_KEEP_HOURS:-72}
OVERPASS_BACKUP_DIR=${OVERPASS_BACKUP_DIR:-}
OVERPASS_BACKUP_TIME=${OVERPASS_BACKUP_TIME:-}
OVERPASS_BACKUP_DAY=${OVERPASS_BACKUP_DAY:-}
OVERPASS_LOG_DIR=${OVERPASS_LOG_DIR:-}
DISPATCHER_BASE_SPACE=${DISPATCHER_BASE_SPACE:-12884901888}
DISPATCHER_BASE_TIME=${DISPATCHER_BASE_TIME:-${DISPATCHER_TIME:-262144}}
DISPATCHER_AREAS_SPACE=${DISPATCHER_AREAS_SPACE:-$DISPATCHER_BASE_SPACE}
DISPATCHER_AREAS_TIME=${DISPATCHER_AREAS_TIME:-$DISPATCHER_BASE_TIME}
DISPATCHER_RATE_LIMIT=${DISPATCHER_RATE_LIMIT:-0}
DISPATCHER_ALLOW_DUPLICATE_QUERIES=${DISPATCHER_ALLOW_DUPLICATE_QUERIES:-yes}
DISPATCHER_LIMIT_CLIENT_ZERO=${DISPATCHER_LIMIT_CLIENT_ZERO:-no}

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

if [[ ! "$DISPATCHER_BASE_TIME" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: DISPATCHER_BASE_TIME must be a positive integer, got: '$DISPATCHER_BASE_TIME'"
  usage
  exit 1
fi

if [[ ! "$DISPATCHER_AREAS_TIME" =~ ^[1-9][0-9]*$ ]]; then
  message "ERROR: DISPATCHER_AREAS_TIME must be a positive integer, got: '$DISPATCHER_AREAS_TIME'"
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

if [[ "$DISPATCHER_LIMIT_CLIENT_ZERO" != "yes" && "$DISPATCHER_LIMIT_CLIENT_ZERO" != "no" ]]; then
  message "ERROR: DISPATCHER_LIMIT_CLIENT_ZERO must be 'yes' or 'no', got: '$DISPATCHER_LIMIT_CLIENT_ZERO'"
  usage
  exit 1
fi

MIN_FREE_DISK_PERCENT=${OVERPASS_MIN_FREE_DISK_PERCENT:-5}
if [[ ! "$MIN_FREE_DISK_PERCENT" =~ ^[0-9]+$ || $MIN_FREE_DISK_PERCENT -ge 100 ]]; then
  message "ERROR: OVERPASS_MIN_FREE_DISK_PERCENT must be an integer from 0 to 99 (got: $MIN_FREE_DISK_PERCENT)"
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
  if ! DB_STATE=$(detect_database_meta_state); then
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

delete_stale_socket_files()
{
  # if $OVERPASS_SOCKET_DIR/osm3s_osm_base exists, warn about a possible uncontrolled shutdown and database corruption and delete the file
  if [[ -S "$OVERPASS_SOCKET_DIR/osm3s_osm_base" ]]; then
    message "WARNING: Stale socket file detected: $OVERPASS_SOCKET_DIR/osm3s_osm_base"
    message "This may indicate an uncontrolled shutdown and potential database corruption"
    message "Deleting stale socket file: $OVERPASS_SOCKET_DIR/osm3s_osm_base"
    rm -f "$OVERPASS_SOCKET_DIR/osm3s_osm_base"
  fi

  # if $OVERPASS_SOCKET_DIR/osm3s_areas exists, warn about a possible uncontrolled shutdown and database corruption and delete the file
  if [[ -S "$OVERPASS_SOCKET_DIR/osm3s_areas" ]]; then
    message "WARNING: Stale socket file detected: $OVERPASS_SOCKET_DIR/osm3s_areas"
    message "This may indicate an uncontrolled shutdown and potential database corruption"
    message "Deleting stale socket file: $OVERPASS_SOCKET_DIR/osm3s_areas"
    rm -f "$OVERPASS_SOCKET_DIR/osm3s_areas"
  fi
}

# ============================================================================
# UPDATE FREQUENCY DETECTION
# ============================================================================

get_path() {
  printf '%03d/%03d/%03d' \
    $(( $1 / 1000000 )) \
    $(( ($1 / 1000) % 1000 )) \
    $(( $1 % 1000 ))
}

get_last_modified() {
  local LAST_MODIFIED
  LAST_MODIFIED=$(curl -sIL "$1" \
    | grep -i '^last-modified:' | tail -1 | tr -d '\r' | sed 's/^[^:]*: //')
  [[ -n "$LAST_MODIFIED" ]] || return 1
  date -d "$LAST_MODIFIED" +%s
}

# Detect the update frequency of the replication source by checking the mean
# interval of Last-Modified times for three state files
# Returns: "60", "3600", or "86400" via stdout
# Returns 1 if the update frequency could not be determined
detect_update_frequency()
{
  local CURRENT_SEQ LAST_MODIFIED_0 LAST_MODIFIED_1 LAST_MODIFIED_2 INTERVAL_1 INTERVAL_2 MEAN_INTERVAL

  CURRENT_SEQ=$(curl -sL "${OVERPASS_DIFF_URL%/}/state.txt" \
    | grep '^sequenceNumber=' | cut -d= -f2 | tr -d '\r')
  if [[ ! "$CURRENT_SEQ" =~ ^[1-9][0-9]*$ ]]; then
    message "ERROR: Failed to read sequence number from ${OVERPASS_DIFF_URL%/}/state.txt"
    return 1
  fi

  LAST_MODIFIED_0=$(get_last_modified "${OVERPASS_DIFF_URL%/}/$(get_path "$CURRENT_SEQ").state.txt") \
    || { message "ERROR: Failed to get Last-Modified time for $(get_path "$CURRENT_SEQ").state.txt"; return 1; }
  LAST_MODIFIED_1=$(get_last_modified "${OVERPASS_DIFF_URL%/}/$(get_path "$((CURRENT_SEQ - 1))").state.txt") \
    || { message "ERROR: Failed to get Last-Modified time for $(get_path "$((CURRENT_SEQ - 1))").state.txt"; return 1; }
  LAST_MODIFIED_2=$(get_last_modified "${OVERPASS_DIFF_URL%/}/$(get_path "$((CURRENT_SEQ - 2))").state.txt") \
    || { message "ERROR: Failed to get Last-Modified time for $(get_path "$((CURRENT_SEQ - 2))").state.txt"; return 1; }

  INTERVAL_1=$(( LAST_MODIFIED_0 - LAST_MODIFIED_1 ))
  INTERVAL_2=$(( LAST_MODIFIED_1 - LAST_MODIFIED_2 ))
  MEAN_INTERVAL=$(( (INTERVAL_1 + INTERVAL_2) / 2 ))

  if   [[ "$MEAN_INTERVAL" -lt 1800  ]]; then printf '%d' 60
  elif [[ "$MEAN_INTERVAL" -lt 43200 ]]; then printf '%d' 3600
  else                                        printf '%d' 86400
  fi

  return 0
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
    --time="$DISPATCHER_BASE_TIME" \
    --rate-limit="$DISPATCHER_RATE_LIMIT" \
    --allow-duplicate-queries="$DISPATCHER_ALLOW_DUPLICATE_QUERIES" \
    --limit-client-zero="$DISPATCHER_LIMIT_CLIENT_ZERO" \
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
      --time="$DISPATCHER_AREAS_TIME" \
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
      message "Check $OVERPASS_DB_DIR/base_dispatcher.out"
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
      message "Check $OVERPASS_DB_DIR/areas_dispatcher.out"
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
  stop_apply_osc
  stop_fetch_osc
  stop_rules_loop
  stop_areas_dispatcher
  stop_base_dispatcher
  stop_backup
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
  DB_DIR="$(realpath "$DB_DIR")"
  if [[ "$EXIT_CODE" -ne 0 || "$DB_DIR" != "$OVERPASS_DB_DIR" ]]; then
    message "ERROR: base dispatcher is not running (exit: $EXIT_CODE, dir: $DB_DIR)"
    message "Check $OVERPASS_DB_DIR/database.log and $OVERPASS_DB_DIR/base_dispatcher.out"
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
  DB_DIR="$(realpath "$DB_DIR")"
  if [[ "$EXIT_CODE" -ne 0 || "$DB_DIR" != "$OVERPASS_DB_DIR" ]]; then
    message "ERROR: areas dispatcher is not running (exit: $EXIT_CODE, dir: $DB_DIR)"
    message "Check $OVERPASS_DB_DIR/areas_dispatcher.out"
    return 1
  fi
  return 0
}

check_apply_osc()
{
  if [[ -n "$APPLY_OSC_PID" ]] && kill -0 "$APPLY_OSC_PID" 2>/dev/null; then
    return 0
  else
    message "ERROR: apply_osc_to_db.sh is not running (PID $APPLY_OSC_PID)"
    message "Check $OVERPASS_DB_DIR/apply_osc_to_db.log and $OVERPASS_DB_DIR/apply_osc_to_db.out"
    return 1
  fi
}

check_fetch_osc()
{
  if [[ -n "$FETCH_OSC_PID" ]] && kill -0 "$FETCH_OSC_PID" 2>/dev/null; then
    return 0
  else
    message "ERROR: fetch_osc.sh is not running (PID $FETCH_OSC_PID)"
    message "Check $OVERPASS_DIFF_DIR/fetch_osc.log and $OVERPASS_DIFF_DIR/fetch_osc.out"
    return 1
  fi
}

check_rules_loop()
{
  [[ "$AREAS" == "no" ]] && return 0
  if [[ -n "$RULES_LOOP_PID" ]] && kill -0 "$RULES_LOOP_PID" 2>/dev/null; then
    return 0
  else
    message "ERROR: rules_loop.sh is not running (PID $RULES_LOOP_PID)"
    message "Check $OVERPASS_DB_DIR/rules_loop.log and $OVERPASS_DB_DIR/rules_loop.out"
    return 1
  fi
}

check_backup()
{
  [[ "$BACKUP" == "no" ]] && return 0
  if [[ -n "$BACKUP_PID" ]] && kill -0 "$BACKUP_PID" 2>/dev/null; then
    return 0
  else
    message "ERROR: backup.sh is not running (PID $BACKUP_PID)"
    message "Check $OVERPASS_DB_DIR/backup.log and $OVERPASS_DB_DIR/backup.out"
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

is_overpass_process()
{
  local pid="$1"
  local cmdline
  [[ "$(readlink "/proc/$pid/exe" 2>/dev/null)" == "$EXEC_DIR/"* ]] && return 0
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  [[ "$cmdline" == *"$EXEC_DIR/"* ]] && return 0
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
      is_overpass_process "$PID" && continue
    fi

    # PID is absent, dead, or not an Overpass process - wait and recheck
    MTIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null) || continue
    sleep_with_interrupts 5
    [[ -f "$LOCK_FILE" ]] || continue
    [[ "$(stat -c %Y "$LOCK_FILE" 2>/dev/null)" == "$MTIME" ]] || continue

    PID=$(< "$LOCK_FILE")
    if [[ "$PID" =~ ^[1-9][0-9]*$ ]] && kill -0 "$PID" 2>/dev/null; then
      is_overpass_process "$PID" && continue
    fi

    message "ERROR: Orphaned lock file detected: $LOCK_FILE (PID: $PID)"
    return 1
  done

  return 0
}

check_disk_space()
{
  [[ -z "$OVERPASS_LOG_DIR" ]] && return 0

  local USED_PCT FREE_PCT
  USED_PCT=$(df --output=pcent "$OVERPASS_LOG_DIR" | tail -1 | tr -d ' %')
  FREE_PCT=$(( 100 - USED_PCT ))
  if [[ $FREE_PCT -lt $MIN_FREE_DISK_PERCENT ]]; then
    message "ERROR: Insufficient free disk space on log filesystem: ${FREE_PCT}% free (minimum: ${MIN_FREE_DISK_PERCENT}%)"
    return 1
  fi
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
    minsize 512k
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
$OVERPASS_LOG_DIR/*.log $OVERPASS_LOG_DIR/*.out {
    daily
    minsize 512k
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
message "OVERPASS_SOCKET_DIR                $OVERPASS_SOCKET_DIR"
message "OVERPASS_STALL_MULTIPLIER          $OVERPASS_STALL_MULTIPLIER"
message "OVERPASS_CLEANUP_INTERVAL          $OVERPASS_CLEANUP_INTERVAL hours"
message "OVERPASS_CLEANUP_KEEP_HOURS        $OVERPASS_CLEANUP_KEEP_HOURS hours"
message "OVERPASS_MIN_FREE_DISK_PERCENT     $MIN_FREE_DISK_PERCENT"
message "DISPATCHER_BASE_SPACE              ~$((DISPATCHER_BASE_SPACE / 1048576)) MiB"
message "DISPATCHER_AREAS_SPACE             ~$((DISPATCHER_AREAS_SPACE / 1048576)) MiB"
message "DISPATCHER_BASE_TIME               $DISPATCHER_BASE_TIME seconds"
message "DISPATCHER_AREAS_TIME              $DISPATCHER_AREAS_TIME seconds"
message "DISPATCHER_RATE_LIMIT              $DISPATCHER_RATE_LIMIT"
message "DISPATCHER_ALLOW_DUPLICATE_QUERIES $DISPATCHER_ALLOW_DUPLICATE_QUERIES"
message "-----------------------------------"

validate_meta_mode

delete_stale_socket_files

if ! OVERPASS_UPDATE_FREQUENCY=$(detect_update_frequency); then
  message "ERROR: Unable to detect update frequency from $OVERPASS_DIFF_URL"
  exit 1
else
  message "Detected update frequency: ${OVERPASS_UPDATE_FREQUENCY}s"
  export OVERPASS_UPDATE_FREQUENCY
fi

generate_logrotate_config

start_base_dispatcher

if ! check_base_dispatcher; then
  message "ERROR: Unable to start base dispatcher"
  message "Check $OVERPASS_DB_DIR/database.log and $OVERPASS_DB_DIR/base_dispatcher.out"
  stop_overpass
  exit 1
fi

start_areas_dispatcher

if ! check_areas_dispatcher; then
  message "ERROR: Unable to start areas dispatcher"
  message "Check $OVERPASS_DB_DIR/areas_dispatcher.out"
  stop_overpass
  exit 1
fi

start_apply_osc

if ! check_apply_osc; then
  message "ERROR: Unable to start apply_osc_to_db.sh"
  message "Check $OVERPASS_DB_DIR/apply_osc_to_db.log and $OVERPASS_DB_DIR/apply_osc_to_db.out"
  stop_overpass
  exit 1
fi

start_fetch_osc

if ! check_fetch_osc; then
  message "ERROR: Unable to start fetch_osc.sh"
  message "Check $OVERPASS_DIFF_DIR/fetch_osc.log and $OVERPASS_DIFF_DIR/fetch_osc.out"
  stop_overpass
  exit 1
fi

start_rules_loop

if ! check_rules_loop; then
  message "ERROR: Unable to start rules_loop.sh"
  message "Check $OVERPASS_DB_DIR/rules_loop.log and $OVERPASS_DB_DIR/rules_loop.out"
  stop_overpass
  exit 1
fi

start_backup

if ! check_backup; then
  message "ERROR: Unable to start backup.sh"
  message "Check $OVERPASS_DB_DIR/backup.log and $OVERPASS_DB_DIR/backup.out"
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
LAST_CLEANUP=0
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

  if ! check_disk_space; then
    message "ERROR: Disk space check failed, shutting down"
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
