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

# ============================================================================
# Script: apply_osc_to_db.sh
# Purpose: Applies downloaded OSM change files to the Overpass database
#          in continuous batches with robust error handling
# ============================================================================

if [[ -z $3 ]]; then
  cat << EOF
Usage: $0 diff_dir replicate_id --meta=(attic|yes|no)

  diff_dir        Directory containing downloaded .osc.gz files
  replicate_id    Starting replicate ID or 'auto' to resume from database state
  --meta          Metadata handling mode (attic=full history, yes=metadata, no=current only)

Environment variables:
  APPLY_OSC_MAX_BATCH_MB             Maximum uncompressed size per batch in MB (default: 512)
  APPLY_OSC_MAX_BATCH_TIME           Maximum time span per batch in seconds (default: 86400)
  OVERPASS_UPDATE_FREQUENCY          Update interval in seconds (default: 60)
  OVERPASS_MIN_FREE_DISK_PERCENT     Minimum free disk space on the database filesystem as a
                                     percentage; updates halt if the threshold is not met (default: 5)
EOF
  exit 1
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

REPLICATE_DIR="$1"
START_ID="$2"
META_ARG="$3"

# Parse metadata argument
META=
if [[ $META_ARG == "--meta=attic" ]]; then
  META="--keep-attic"
elif [[ $META_ARG == "--meta=yes" || $META_ARG == "--meta" ]]; then
  META="--meta"
elif [[ $META_ARG == "--meta=no" ]]; then
  META=
else
  echo "ERROR: You must specify --meta=attic, --meta=yes, or --meta=no"
  exit 1
fi

# Batch configuration
MAX_BATCH_MB=${APPLY_OSC_MAX_BATCH_MB:-512}       # Maximum uncompressed size per batch (MB)
MAX_BATCH_TIME=${APPLY_OSC_MAX_BATCH_TIME:-86400} # Maximum time span per batch (1 day = 86400 seconds)

# Disk space configuration
MIN_FREE_DISK_PERCENT=${OVERPASS_MIN_FREE_DISK_PERCENT:-5}
if [[ ! "$MIN_FREE_DISK_PERCENT" =~ ^[0-9]+$ || $MIN_FREE_DISK_PERCENT -ge 100 ]]; then
  echo "ERROR: OVERPASS_MIN_FREE_DISK_PERCENT must be an integer from 0 to 99 (got: $MIN_FREE_DISK_PERCENT)"
  exit 1
fi

# Update configuration
UPDATE_FREQUENCY=${OVERPASS_UPDATE_FREQUENCY:-60}        # Frequency of updates in seconds
TRIM=$(( (UPDATE_FREQUENCY + 23) / 24 ))                 # Start polling this many seconds before expected update

# Child process tracking
CHILD_PID=                                        # PID of running migrate_database or update_from_dir processes
INOTIFY_PID=                                      # PID of running inotifywait process

# Get execution directory
EXEC_DIR="$(realpath "$(dirname "$0")")"

# Convert replicate dir to absolute path
REPLICATE_DIR="$(realpath "$REPLICATE_DIR")"

# Get database directory
DB_DIR=$("$EXEC_DIR"/dispatcher --show-dir)
DB_DIR="$(realpath "$DB_DIR")"

if [[ ! -d "$DB_DIR" ]]; then
  echo "ERROR: Database directory '$DB_DIR' does not exist"
  exit 1
fi

# Check for buggy date implementation
DATE_CHECK=$(date -d "2026-01-31T20:00:30Z" +%s 2>/dev/null)
if [[ "$?" -ne 0 || "$DATE_CHECK" -ne 1769889630 ]]; then
  echo "ERROR: The 'date' command on this system cannot parse ISO-8601 timestamps (e.g., 2026-01-31T20:00:30Z) used in OSM data."
  echo "Update your system packages, install GNU date, or use the Docker container instead."
  exit 1
fi

# State file
STATE_FILE="$DB_DIR/replicate_id"

# Log file
LOG_FILE="$DB_DIR/apply_osc_to_db.log"

# PID file
PID_FILE="$DB_DIR/apply_osc.pid"
echo "$$" > "$PID_FILE" || { echo "ERROR: Unable to write PID file: $PID_FILE"; exit 1; }

# Working directory for decompressed files (created in main execution section)
WORK_DIR=

# Detect inotifywait for efficient batch waiting
USE_INOTIFYWAIT=false
if command -v inotifywait > /dev/null 2>&1; then
  USE_INOTIFYWAIT=true
fi
INOTIFY_WATCHDOG_SLACK=30  # seconds beyond --timeout before declaring inotifywait unreliable

# ============================================================================
# CLEANUP
# ============================================================================

die()
{
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR" 2>/dev/null || true
  fi
  rm -f "$PID_FILE" 2>/dev/null || true
  exit "$1"
}

# ============================================================================
# LOGGING
# ============================================================================

IN_TERMINAL="false"
[ -t 1 ] && IN_TERMINAL="true"

log_message()
{
  if [[ "$IN_TERMINAL" == "true" ]]; then
    echo "$(date -u '+%F %T'): $1" | tee -a "$LOG_FILE"
  else
    echo "$(date -u '+%F %T'): $1" >> "$LOG_FILE"
  fi
}

log_error()
{
  if [[ "$IN_TERMINAL" == "true" ]]; then
    echo "$(date -u '+%F %T'): ERROR: $1" | tee -a "$LOG_FILE"
  else
    echo "$(date -u '+%F %T'): ERROR: $1" >> "$LOG_FILE"
  fi
}

# ============================================================================
# DATABASE STATE DETECTION
# ============================================================================

# Detect the meta mode of the database by checking for characteristic files
# Returns: "no", "yes", or "attic" via stdout
# Returns 1 if base files are missing (database not initialized)
detect_database_meta_state()
{
  # Check for attic files (most specific check first)
  if [[ -f "$DB_DIR/nodes_attic.bin" || -f "$DB_DIR/node_changelog.bin" || -f "$DB_DIR/ways_attic.bin" ]]; then
    echo "attic"
    return 0
  fi

  # Check for meta files
  if [[ -f "$DB_DIR/nodes_meta.bin" || -f "$DB_DIR/ways_meta.bin" || -f "$DB_DIR/user_data.bin" ]]; then
    echo "yes"
    return 0
  fi

  # No meta or attic files found - verify base files exist
  if [[ ! -f "$DB_DIR/nodes.bin" || ! -f "$DB_DIR/ways.bin" || ! -f "$DB_DIR/relations.bin" ]]; then
    return 1
  fi

  echo "no"
  return 0
}

# Validate that user-specified meta mode matches database state
validate_meta_mode()
{
  # Extract the mode from the argument
  local USER_MODE="${META_ARG#--meta=}"

  # Detect actual database state
  local DB_STATE
  DB_STATE=$(detect_database_meta_state)
  if [[ $? -ne 0 ]]; then
    log_message "WARNING: Database directory does not contain required base files (nodes.bin, ways.bin, relations.bin)"
    log_message "The database may not be properly initialized"
    return 0
  fi

  # Compare user mode with database state
  if [[ "$USER_MODE" != "$DB_STATE" ]]; then
    log_message "WARNING: Meta mode mismatch. Argument: --meta=$USER_MODE; Database: --meta=$DB_STATE"
    log_message "Proceeding with user-specified mode: --meta=$USER_MODE"
  fi
}

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

read_current_state()
{
  if [[ -f "$STATE_FILE" && -s "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
    return 0
  else
    return 1
  fi
}

update_state()
{
  local NEW_ID=$1
  if ! {  echo "$NEW_ID" > "$STATE_FILE.tmp"; }; then
    log_error "Failed to write new state to temporary file"
    die 1
  fi
  if ! mv "$STATE_FILE.tmp" "$STATE_FILE"; then
    log_error "Failed to update state file"
    die 1
  fi
}

# ============================================================================
# PATH CONVERSION
# ============================================================================

get_replicate_path()
{
  local ID=$1
  printf -v DIGIT3 %03u $((ID % 1000))
  local ARG=$((ID / 1000))
  printf -v DIGIT2 %03u $((ARG % 1000))
  ARG=$((ARG / 1000))
  printf -v DIGIT1 %03u $ARG
  REPLICATE_PATH="$DIGIT1/$DIGIT2/$DIGIT3"
}

# ============================================================================
# FILE VERIFICATION
# ============================================================================

verify_file()
{
  local FILE="$1"
  local TYPE="$2"
  
  if [[ ! -s "$FILE" ]]; then
    return 1
  fi
  
  if [[ "$TYPE" == "gzip" ]]; then
    gunzip -t <"$FILE" 2>/dev/null
    return $?
  elif [[ "$TYPE" == "text" ]]; then
    if ! grep -q "^sequenceNumber=" "$FILE" 2>/dev/null; then
      return 1
    fi
    if ! grep -q "^timestamp=" "$FILE" 2>/dev/null; then
      return 1
    fi
    return 0
  fi
  
  return 1
}

# ============================================================================
# BATCH COLLECTION
# ============================================================================

# Helper function to extract timestamp from state file and convert to epoch seconds
get_timestamp_epoch()
{
  local STATE_FILE_PATH="$1"

  if [[ ! -f "$STATE_FILE_PATH" ]]; then
    return 1
  fi

  local TIMESTAMP_LINE
  TIMESTAMP_LINE=$(grep "^timestamp=" "$STATE_FILE_PATH" 2>/dev/null)

  if [[ -z "$TIMESTAMP_LINE" ]]; then
    return 1
  fi

  # Extract timestamp value (format: 2021-01-01T00\:00\:00Z)
  local TIMESTAMP_STR="${TIMESTAMP_LINE#timestamp=}"

  # Convert escaped colons to regular colons
  TIMESTAMP_STR="${TIMESTAMP_STR//\\:/:}"

  # Convert to epoch seconds using date command
  date -d "$TIMESTAMP_STR" +%s 2>/dev/null
  return $?
}

collect_batch()
{
  local START=$1
  local ID=$((START + 1))

  BATCH_END=$START

  local BATCH_SIZE_BYTES=0
  local MAX_BATCH_SIZE_BYTES=$((MAX_BATCH_MB * 1024 * 1024))
  local BATCH_START_TIMESTAMP=""

  # Find contiguous downloaded files until size or time limit reached
  while true; do
    get_replicate_path $ID

    local OSC_FILE="$REPLICATE_DIR/$REPLICATE_PATH.osc.gz"
    local STATE_FILE_LOCAL="$REPLICATE_DIR/$REPLICATE_PATH.state.txt"

    # Check if files exist
    if [[ ! -f "$OSC_FILE" || ! -f "$STATE_FILE_LOCAL" ]]; then
      break
    fi

    # Verify file integrity
    if ! verify_file "$OSC_FILE" "gzip"; then
      log_error "Corrupt .osc.gz file: $OSC_FILE"
      break
    fi
    if ! verify_file "$STATE_FILE_LOCAL" "text"; then
      log_error "Corrupt .state.txt file: $STATE_FILE_LOCAL"
      break
    fi

    # Get uncompressed size of this file
    local UNCOMPRESSED_SIZE
    UNCOMPRESSED_SIZE=$(gunzip -l "$OSC_FILE" 2>/dev/null | tail -1 | awk '{print $2}')
    if [[ -z "$UNCOMPRESSED_SIZE" || "$UNCOMPRESSED_SIZE" -le 0 ]]; then
      log_error "Cannot determine uncompressed size of $OSC_FILE"
      break
    fi

    # Check size limit: is the current batch already at or over the limit?
    if [[ $BATCH_SIZE_BYTES -gt $MAX_BATCH_SIZE_BYTES ]]; then
      break
    fi

    local NEW_BATCH_SIZE=$((BATCH_SIZE_BYTES + UNCOMPRESSED_SIZE))

    # Get timestamp for this file
    local FILE_TIMESTAMP_EPOCH
    FILE_TIMESTAMP_EPOCH=$(get_timestamp_epoch "$STATE_FILE_LOCAL")
    if [[ $? -ne 0 || -z "$FILE_TIMESTAMP_EPOCH" ]]; then
      log_error "Cannot extract timestamp from $STATE_FILE_LOCAL"
      break
    fi

    # Set starting timestamp on first file
    if [[ -z "$BATCH_START_TIMESTAMP" ]]; then
      BATCH_START_TIMESTAMP="$FILE_TIMESTAMP_EPOCH"
    fi

    # Check time limit: would adding this file exceed the time span?
    local TIME_SPAN=$((FILE_TIMESTAMP_EPOCH - BATCH_START_TIMESTAMP))
    if [[ $TIME_SPAN -ge MAX_BATCH_TIME ]]; then
      break
    fi

    # File passes all checks - add it to the batch
    BATCH_END=$ID
    BATCH_SIZE_BYTES=$NEW_BATCH_SIZE
    ID=$((ID + 1))
  done

  if [[ $BATCH_END -le $START ]]; then
    return 1
  fi

  local COUNT=$((BATCH_END - START))
  if [[ $COUNT -eq 1 ]]; then
    log_message "Collected one file: $BATCH_END"
  else
    log_message "Collected batch: $START to $BATCH_END ($COUNT files)"
  fi
  return 0
}

# ============================================================================
# BATCH PREPARATION
# ============================================================================

prepare_batch()
{
  local START=$1
  local END=$2
  local COUNT=$((END - START))
  local OUT_DIR="$3"

  if ! mkdir -p "$OUT_DIR"; then
    log_error "Unable to create output directory $OUT_DIR"
    return 1
  fi

  if [[ $COUNT -eq 1 ]]; then
    log_message "Decompressing file: $END"
  else
    log_message "Decompressing batch: $START to $END ($COUNT files)"
  fi

  for (( ID=START+1; ID<=END; ID++ )); do
    get_replicate_path "$ID"

    local OSC_GZ="$REPLICATE_DIR/$REPLICATE_PATH.osc.gz"

    if [[ ! -f "$OSC_GZ" ]]; then
      log_error "Missing file: $OSC_GZ"
      return 1
    fi

    printf -v OUT_FILE %09u "$ID"

    if ! gunzip -c "$OSC_GZ" >"$OUT_DIR/$OUT_FILE.osc"; then
      log_error "Failed to decompress $OSC_GZ"
      return 1
    fi
  done

  return 0
}

# ============================================================================
# TIMESTAMP EXTRACTION
# ============================================================================

get_timestamp()
{
  local ID=$1
  get_replicate_path "$ID"

  local STATE_FILE_LOCAL="$REPLICATE_DIR/$REPLICATE_PATH.state.txt"

  # read the local state file carefully, as it may not be fully written yet
  local TIMESTAMP_LINE=""
  local WAIT_COUNT=0
  while [[ -z "$TIMESTAMP_LINE" && $WAIT_COUNT -lt 10 ]]; do
    TIMESTAMP_LINE=$(grep "^timestamp" <"$STATE_FILE_LOCAL" 2>/dev/null)
    if [[ -z "$TIMESTAMP_LINE" ]]; then
      sleep_with_interrupts 1
      WAIT_COUNT=$((WAIT_COUNT + 1))
    fi
  done

  if [[ -z "$TIMESTAMP_LINE" ]]; then
    log_error "Could not extract timestamp from $STATE_FILE_LOCAL"
    return 1
  fi

  DATA_VERSION=${TIMESTAMP_LINE:10}
  return 0
}

# ============================================================================
# BATCH APPLICATION
# ============================================================================

apply_batch()
{
  local OSC_DIR="$1"

  log_message "Applying batch to database (version: ${DATA_VERSION//\\/})"

  if ! cd "$EXEC_DIR"; then
    log_error "Unable to cd to execution directory"
    die 1
  fi

  local SUCCESS=0
  local RETRY_COUNT=0
  local MAX_RETRIES=5

  while [[ $SUCCESS -eq 0 && $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    ./update_from_dir --osc-dir="$OSC_DIR" --version="$DATA_VERSION" $META --flush-size=0 &
    CHILD_PID="$!"
    wait "$CHILD_PID"
    local EXIT_CODE=$?
    CHILD_PID=

    if [[ $EXIT_CODE -eq 0 ]]; then
      SUCCESS=1
    elif [[ $EXIT_CODE -eq 3 ]]; then
      log_error "update_from_dir failed due to context error (exit code: $EXIT_CODE)"
      log_message "Resolve the problem with the dispatcher before retrying"
      cd - >/dev/null || true
      log_error "Dispatcher failure, cannot proceed"
      die 1
    elif [[ $EXIT_CODE -eq 15 ]]; then
      log_message "Received SIGTERM in update_from_dir, shutting down gracefully"
      cd - >/dev/null || true
      shutdown 143
    elif [[ $EXIT_CODE -eq 126 || $EXIT_CODE -eq 127 ]]; then
      # Unrecoverable errors: command not executable (126) or not found (127)
      log_error "Unable to run update_from_dir (exit code: $EXIT_CODE)"
      cd - >/dev/null || true
      log_error "update_from_dir is not available or not executable"
      die 1
    elif [[ $EXIT_CODE -eq 134 ]]; then
      log_error "Received SIGABRT (exit code: $EXIT_CODE) from update_from_dir, shutting down"
      log_error "Database may be corrupt; verify or restore from backup before resuming updates"
      cd - >/dev/null || true
      shutdown $EXIT_CODE
    elif [[ $EXIT_CODE -ge 128 && $EXIT_CODE -le 165 ]]; then
      # Signal-based exits: process was killed/crashed (128+N where N is signal number)
      log_error "update_from_dir terminated by signal (exit code: $EXIT_CODE), cleaning up..."
      cd - >/dev/null || true
      shutdown $EXIT_CODE
    else
      RETRY_COUNT=$((RETRY_COUNT + 1))
      if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
        log_error "update_from_dir failed (exit code: $EXIT_CODE), attempt $((RETRY_COUNT + 1))/$MAX_RETRIES, retrying..."
        sleep_with_interrupts "$UPDATE_FREQUENCY"
      else
        log_error "update_from_dir error is not recoverable after $MAX_RETRIES attempts"
      fi
    fi
  done

  if ! cd - >/dev/null; then
    log_error "Unable to cd back to previous directory"
    die 1
  fi

  if [[ $SUCCESS -eq 0 ]]; then
    log_error "Failed to apply batch after $MAX_RETRIES attempts"
    return 1
  fi

  return 0
}

# ============================================================================
# SLEEPING
# ============================================================================

sleep_with_interrupts()
{
  sleep "$1" &
  wait $!
}

# ============================================================================
# BATCH WAITING
# ============================================================================

wait_for_batch()
{
  local NOW FETCH_MTIME SLEEP_TARGET SLEEP_TIME LOG_INTERVAL ELAPSED INOTIFY_EXIT CURRENT_MTIME

  LOG_INTERVAL=$(( UPDATE_FREQUENCY / 6 ))
  (( LOG_INTERVAL < 1 )) && LOG_INTERVAL=1

  NOW=$(date +%s)
  FETCH_MTIME=$(stat -c %Y "$REPLICATE_DIR/replicate_id" 2>/dev/null) || FETCH_MTIME=0
  SLEEP_TARGET=$(( FETCH_MTIME + UPDATE_FREQUENCY - TRIM ))
  SLEEP_TIME=$(( SLEEP_TARGET - NOW ))

  # Phase 1: initial sleep before update window opens
  if [[ $SLEEP_TIME -gt 0 ]]; then
    log_message "Next batch expected in $SLEEP_TIME seconds at $(date -d "@$SLEEP_TARGET" -u '+%F %T')"
    if [[ "$USE_INOTIFYWAIT" == "true" ]]; then
      timeout "$((SLEEP_TIME + INOTIFY_WATCHDOG_SLACK))" \
        inotifywait -q -e moved_to \
          --include "$REPLICATE_DIR/replicate_id" \
          --timeout "$SLEEP_TIME" \
          "$REPLICATE_DIR" > /dev/null &
      INOTIFY_PID=$!
      sleep 0.1
      CURRENT_MTIME=$(stat -c %Y "$REPLICATE_DIR/replicate_id" 2>/dev/null) || CURRENT_MTIME=0
      if [[ "$CURRENT_MTIME" != "$FETCH_MTIME" ]]; then
        kill "$INOTIFY_PID" 2>/dev/null || true
        wait "$INOTIFY_PID" 2>/dev/null || true
        INOTIFY_PID=
      else
        wait "$INOTIFY_PID"
        INOTIFY_EXIT=$?
        INOTIFY_PID=
        if [[ $INOTIFY_EXIT -eq 1 ]]; then
          log_error "inotifywait failed (exit $INOTIFY_EXIT), falling back to timed polling"
          USE_INOTIFYWAIT=false
        elif [[ $INOTIFY_EXIT -eq 124 ]]; then
          # See https://github.com/inotify-tools/inotify-tools/issues/243
          log_message "WARNING: Watchdog ended wait period because inotifywait --timeout did not work"
        fi
      fi
    else
      sleep_with_interrupts "$SLEEP_TIME"
    fi
    return 0
  fi

  # Phase 2: polling window
  [[ -z "$POLL_START" ]] && POLL_START=$NOW
  ELAPSED=$(( NOW - POLL_START ))

  if [[ $ELAPSED -ge $((UPDATE_FREQUENCY * 2)) ]]; then
    log_message "No new batch after ${ELAPSED}s, is fetch_osc.sh running?"
  elif [[ $ELAPSED -ge $UPDATE_FREQUENCY ]]; then
    log_message "Next batch is overdue (${ELAPSED}s)"
  elif [[ $ELAPSED -eq 0 ]]; then
    log_message "Waiting for next batch"
  else
    log_message "Still waiting for next batch (${ELAPSED}s)"
  fi

  if [[ "$USE_INOTIFYWAIT" == "true" ]]; then
    timeout "$((LOG_INTERVAL + INOTIFY_WATCHDOG_SLACK))" \
      inotifywait -q -e moved_to \
        --include "$REPLICATE_DIR/replicate_id" \
        --timeout "$LOG_INTERVAL" \
        "$REPLICATE_DIR" > /dev/null &
    INOTIFY_PID=$!
    sleep 0.1
    CURRENT_MTIME=$(stat -c %Y "$REPLICATE_DIR/replicate_id" 2>/dev/null) || CURRENT_MTIME=0
    if [[ "$CURRENT_MTIME" != "$FETCH_MTIME" ]]; then
      kill "$INOTIFY_PID" 2>/dev/null || true
      wait "$INOTIFY_PID" 2>/dev/null || true
      INOTIFY_PID=
    else
      wait "$INOTIFY_PID"
      INOTIFY_EXIT=$?
      INOTIFY_PID=
      if [[ $INOTIFY_EXIT -eq 1 ]]; then
        log_error "inotifywait failed (exit $INOTIFY_EXIT), falling back to timed polling"
        USE_INOTIFYWAIT=false
      elif [[ $INOTIFY_EXIT -eq 124 ]]; then
        # See https://github.com/inotify-tools/inotify-tools/issues/243
        log_message "WARNING: Watchdog ended wait period because inotifywait --timeout did not work"
      fi
    fi
  else
    local POLL_INTERVAL PHASE2_START
    POLL_INTERVAL=$(( UPDATE_FREQUENCY / 600 ))
    (( POLL_INTERVAL < 1 )) && POLL_INTERVAL=1
    PHASE2_START=$(date +%s)
    while true; do
      CURRENT_MTIME=$(stat -c %Y "$REPLICATE_DIR/replicate_id" 2>/dev/null) || CURRENT_MTIME=0
      if [[ "$CURRENT_MTIME" != "$FETCH_MTIME" ]]; then
        break
      fi
      if [[ $(( $(date +%s) - PHASE2_START )) -ge $LOG_INTERVAL ]]; then
        break
      fi
      sleep_with_interrupts "$POLL_INTERVAL"
    done
  fi
}

# ============================================================================
# DISK SPACE CHECK
# ============================================================================

check_db_disk_space()
{
  local USED_PCT FREE_PCT
  USED_PCT=$(df --output=pcent "$DB_DIR" | tail -1 | tr -d ' %')
  FREE_PCT=$(( 100 - USED_PCT ))
  if [[ $FREE_PCT -lt $MIN_FREE_DISK_PERCENT ]]; then
    log_error "Insufficient free disk space on database filesystem: ${FREE_PCT}% free (minimum: ${MIN_FREE_DISK_PERCENT}%)"
    die 1
  fi
}

# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

shutdown()
{
  local EXIT_CODE=$1
  log_message "Shutdown signal received, cleaning up..."

  # Temporarily ignore signals to prevent recursion
  trap '' SIGTERM SIGINT SIGHUP

  # Kill inotifywait if running
  if [[ -n "$INOTIFY_PID" ]]; then
    kill "$INOTIFY_PID" 2>/dev/null || true
    wait "$INOTIFY_PID" 2>/dev/null || true
    INOTIFY_PID=
  fi

  # Wait for migrate_database or update_from_dir to complete
  if [[ -n "$CHILD_PID" ]]; then
    wait "$CHILD_PID"
  fi

  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR" 2>/dev/null || true
  fi
  rm -f "$PID_FILE" 2>/dev/null || true

  log_message "Shutdown complete"
  exit "$EXIT_CODE"
}

trap 'shutdown 143' SIGTERM
trap 'shutdown 130' SIGINT
trap 'shutdown 129' SIGHUP

# ============================================================================
# MAIN EXECUTION
# ============================================================================

log_message "-----------------------------------"
log_message "Starting Apply Process ($0)"
log_message "-----------------------------------"
log_message "OVERPASS_DIFF_DIR                  $REPLICATE_DIR"
log_message "OVERPASS_REPLICATE_ID              $START_ID"
log_message "OVERPASS_META_MODE                 ${META_ARG#--meta=}"
log_message "APPLY_OSC_MAX_BATCH_MB             $MAX_BATCH_MB"
log_message "APPLY_OSC_MAX_BATCH_TIME           $MAX_BATCH_TIME"
log_message "OVERPASS_UPDATE_FREQUENCY          $UPDATE_FREQUENCY"
log_message "OVERPASS_MIN_FREE_DISK_PERCENT     $MIN_FREE_DISK_PERCENT"
log_message "-----------------------------------"
if [[ "$USE_INOTIFYWAIT" == "true" ]]; then
  log_message "Batch wait mode: tracking file updates using inotifywait"
else
  log_message "Batch wait mode: timed polling (inotifywait not available)"
fi

if [[ "$START_ID" == "auto" ]]; then
  CURRENT_ID=$(read_current_state)
  if [[ $? -ne 0 ]]; then
    log_error "$STATE_FILE does not exist and start set to auto"
    log_error "Auto mode requires an existing replicate_id to resume from"
    log_error "Use an explicit replicate ID to specify the starting point"
    die 1
  fi
  if [[ $CURRENT_ID -lt 0 ]]; then
    log_error "Current replicate ID in database is invalid: $CURRENT_ID"
    die 1
  fi
  log_message "Auto mode: resuming from $CURRENT_ID"
else
  CURRENT_ID=$START_ID
  if [[ $CURRENT_ID -lt 0 ]]; then
    log_error "Specified start replicate ID is invalid: $CURRENT_ID"
    die 1
  fi
  log_message "Starting from $CURRENT_ID"
fi

# Pre-flight check: verify state file is writeable before doing any work
if ! touch "$STATE_FILE"; then
  log_error "State file $STATE_FILE is not writeable"
  die 1
fi

validate_meta_mode

# Run database migration
log_message "Running database migration"
if ! cd "$EXEC_DIR"; then
  log_error "Unable to cd to execution directory"
  die 1
fi
./migrate_database --migrate &
CHILD_PID=$!
wait "$CHILD_PID"
EXIT_CODE=$?
CHILD_PID=
if [[ $EXIT_CODE -ne 0 ]]; then
  log_error "Database migration failed"
  die 1
fi
if ! cd - >/dev/null; then
  log_error "Unable to cd back to previous directory"
  die 1
fi

# Delete old temp files
log_message "Deleting old temporary files and directories"
rm -rf "${TMPDIR:-/tmp}"/osm-3s_update_*

# Create working directory for decompressed files
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/osm-3s_update_XXXXXX")
if [[ ! -d "$WORK_DIR" ]]; then
  log_error "Unable to create working directory"
  die 1
fi

START_TIME=$(date +%s)
POLL_START=

while true; do
  check_db_disk_space

  # Try to collect a batch
  if ! collect_batch "$CURRENT_ID"; then
    if [[ -n "$START_TIME" && $(date +%s) -gt $((START_TIME + UPDATE_FREQUENCY * 2)) ]]; then
      log_error "No new files to process after two update cycles. Is fetch_osc.sh running?"
      die 1
    fi
    wait_for_batch
    continue
  fi

  START_TIME=
  POLL_START=

  # Prepare processing directory
  PROCESS_DIR="$WORK_DIR/process_$BATCH_END"
  rm -rf "$PROCESS_DIR"
  if ! mkdir -p "$PROCESS_DIR"; then
    log_error "Unable to create processing directory $PROCESS_DIR"
    die 1
  fi

  # Decompress batch
  if ! prepare_batch "$CURRENT_ID" "$BATCH_END" "$PROCESS_DIR"; then
    log_error "Failed to prepare batch, skipping"
    rm -rf "$PROCESS_DIR"
    sleep_with_interrupts "$UPDATE_FREQUENCY"
    continue
  fi

  # Get timestamp
  if ! get_timestamp "$BATCH_END"; then
    log_error "Failed to get timestamp, skipping batch"
    rm -rf "$PROCESS_DIR"
    sleep_with_interrupts "$UPDATE_FREQUENCY"
    continue
  fi

  # Apply batch
  if ! apply_batch "$PROCESS_DIR"; then
    log_error "Failed to apply batch, will retry"
    rm -rf "$PROCESS_DIR"
    sleep_with_interrupts "$UPDATE_FREQUENCY"
    continue
  fi

  # Success - update state
  update_state "$BATCH_END"
  CURRENT_ID=$BATCH_END

  log_message "Successfully applied batch up to $CURRENT_ID"

  # Clean up
  rm -rf "$PROCESS_DIR"
done
