#!/usr/bin/env bash

# Copyright 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018 Roland Olbricht et al.
# With improvements in 2025 by Kai Johnson
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

# Ensure the script is its own process group leader
# (only needed if the script might be run from an interactive shell)
PGID=$(ps -o pgid= $$ 2>/dev/null | tr -d ' ')
if [[ -z "$PGID" ]]; then
  echo "ERROR: Unable to determine process group ID"
  exit 1
fi
if [[ $$ -ne $PGID ]]; then
  exec setsid "$0" "$@"
  # If exec fails, we get here
  echo "ERROR: Unable to create new process group with setsid"
  exit 1
fi

if [[ -z $3 ]]; then
{
  echo "Usage: $0 replicate_dir start_id --meta=(attic|yes|no)"
  echo ""
  echo "  replicate_dir: Directory containing downloaded replicate files"
  echo "  start_id:      Starting replicate ID or 'auto' to resume from database state"
  echo "  --meta:        Metadata handling mode (attic=full history, yes=metadata, no=current only)"
  exit 1
}; fi

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
MAX_BATCH_MB=${APPLY_OSC_TO_DB_MAX_BATCH_MB:-512}       # Maximum uncompressed size per batch (MB)
MAX_BATCH_TIME=${APPLY_OSC_TO_DB_MAX_BATCH_TIME:-86400} # Maximum time span per batch (1 day = 86400 seconds)

# Update configuration
UPDATE_FREQUENCY=${OVERPASS_UPDATE_FREQUENCY:-60}       # Frequency of updates in seconds
UPDATE_TRIM=${APPLY_OSC_TO_DB_UPDATE_TRIM:--3}          # Seconds to adjust expected update time

# Timestamp tracking
LAST_UPDATE_WALL_CLOCK=                                 # Wall clock time when last update was collected

# Get execution directory
EXEC_DIR="$(dirname "$0")/"
if [[ ! ${EXEC_DIR:0:1} == "/" ]]; then
  EXEC_DIR="$(pwd)/$EXEC_DIR"
fi

# Convert replicate dir to absolute path
if [[ ! ${REPLICATE_DIR:0:1} == "/" ]]; then
  REPLICATE_DIR="$(pwd)/$REPLICATE_DIR"
fi

# Get database directory
DB_DIR=$("$EXEC_DIR"/dispatcher --show-dir)
# Strip trailing slash if present
DB_DIR="${DB_DIR%/}"

if [[ ! -d "$DB_DIR" ]]; then
  echo "ERROR: Database directory '$DB_DIR' does not exist"
  exit 1
fi

# State file
STATE_FILE="$DB_DIR/replicate_id"

# Log file
LOG_FILE="$DB_DIR/apply_osc_to_db.log"

# Working directory for decompressed files
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/osm-3s_update_XXXXXX")
if [[ ! -d "$WORK_DIR" ]]; then
  log_error "Unable to create working directory"
  exit 1
fi

# ============================================================================
# LOGGING
# ============================================================================

log_message()
{
  echo "$(date -u '+%F %T'): $1" | tee -a "$LOG_FILE"
}

log_error()
{
  echo "$(date -u '+%F %T'): ERROR: $1" | tee -a "$LOG_FILE"
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
    exit 1
  fi
  if ! mv "$STATE_FILE.tmp" "$STATE_FILE"; then
    log_error "Failed to update state file"
    exit 1
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

  mkdir -p "$OUT_DIR"

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
    exit 1
  fi

  local SUCCESS=0
  local RETRY_COUNT=0
  local MAX_RETRIES=5

  while [[ $SUCCESS -eq 0 && $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    ./update_from_dir --osc-dir="$OSC_DIR" --version="$DATA_VERSION" $META --flush-size=0 &
    wait "$!"
    local EXITCODE=$?

    if [[ $EXITCODE -eq 0 ]]; then
      SUCCESS=1
    elif [[ $EXITCODE -eq 3 ]]; then
      log_error "update_from_dir failed due to context error (exit code: $EXITCODE)"
      log_message "Resolve the problem with the dispatcher before retrying"
      cd - >/dev/null || true
      log_error "Dispatcher failure, cannot proceed"
      exit 1
    elif [[ $EXITCODE -eq 15 ]]; then
      log_message "Received SIGTERM in update_from_dir, shutting down gracefully"
      cd - >/dev/null || true
      shutdown 143
    elif [[ $EXITCODE -eq 126 || $EXITCODE -eq 127 ]]; then
      # Unrecoverable errors: command not executable (126) or not found (127)
      log_error "Unable to run update_from_dir (exit code: $EXITCODE)"
      cd - >/dev/null || true
      log_error "update_from_dir is not available or not executable"
      exit 1
    elif [[ $EXITCODE -ge 128 && $EXITCODE -le 165 ]]; then
      # Signal-based exits: process was killed/crashed (128+N where N is signal number)
      log_error "update_from_dir terminated by signal (exit code: $EXITCODE), cleaning up..."
      cd - >/dev/null || true
      shutdown $EXITCODE
    else
      RETRY_COUNT=$((RETRY_COUNT + 1))
      if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
        log_error "update_from_dir failed (exit code: $EXITCODE), attempt $((RETRY_COUNT + 1))/$MAX_RETRIES, retrying..."
        sleep_with_interrupts "$UPDATE_FREQUENCY"
      else
        log_error "update_from_dir error is not recoverable after $MAX_RETRIES attempts"
      fi
    fi
  done

  if ! cd - >/dev/null; then
    log_error "Unable to cd back to previous directory"
    exit 1
  fi

  if [[ $SUCCESS -eq 0 ]]; then
    log_error "Failed to apply batch after $MAX_RETRIES attempts"
    return 1
  fi

  return 0
}

# ============================================================================
# TIMING
# ============================================================================

calculate_sleep_time()
{
  if [[ -z "$LAST_UPDATE_WALL_CLOCK" ]]; then
    echo 5
    return
  fi

  local NOW
  NOW=$(date +%s)
  local NEXT_CHECK=$((LAST_UPDATE_WALL_CLOCK + UPDATE_FREQUENCY + UPDATE_TRIM))
  local SLEEP_TIME=$((NEXT_CHECK - NOW))

  if [[ $SLEEP_TIME -lt 1 ]]; then
    echo 1
  else
    echo $SLEEP_TIME
  fi
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
# SIGNAL HANDLERS
# ============================================================================

shutdown()
{
  local EXIT_CODE=$1
  log_message "Shutdown signal received, cleaning up..."

  # Temporarily ignore signals to prevent recursion
  trap '' SIGTERM SIGINT SIGHUP

  # Kill all processes in the process group except ourselves
  kill -TERM -- -$$ 2>/dev/null || true

  # Wait for children to finish
  wait 2>/dev/null || true

  rm -rf "$WORK_DIR"

  log_message "Shutdown complete"
  exit "$EXIT_CODE"
}

trap 'shutdown 143' SIGTERM
trap 'shutdown 130' SIGINT
trap 'shutdown 129' SIGHUP

# ============================================================================
# MAIN EXECUTION
# ============================================================================

log_message "Starting apply process from $REPLICATE_DIR with $META_ARG"

if [[ "$START_ID" == "auto" ]]; then
  CURRENT_ID=$(read_current_state)
  if [[ $? -ne 0 ]]; then
    log_error "$STATE_FILE does not exist and start set to auto"
    log_error "Auto mode requires an existing replicate_id to resume from"
    log_error "Use an explicit replicate ID to specify the starting point"
    exit 1
  fi
  if [[ $CURRENT_ID -lt 0 ]]; then
    log_error "Current replicate ID in database is invalid: $CURRENT_ID"
    exit 1
  fi
  log_message "Auto mode: resuming from $CURRENT_ID"
else
  CURRENT_ID=$START_ID
  if [[ $CURRENT_ID -lt 0 ]]; then
    log_error "Specified start replicate ID is invalid: $CURRENT_ID"
    exit 1
  fi
  log_message "Starting from $CURRENT_ID"
fi

validate_meta_mode

# Run database migration
log_message "Running database migration"
if ! cd "$EXEC_DIR"; then
  log_error "Unable to cd to execution directory"
  exit 1
fi
./migrate_database --migrate &
if ! wait "$!"; then
  log_error "Database migration failed"
  exit 1
fi
if ! cd - >/dev/null; then
  log_error "Unable to cd back to previous directory"
  exit 1
fi

# Delete old temp files
log_message "Deleting old temporary files and directories"
rm -rf "${TMPDIR:-/tmp}"/osm-3s_update_*

START_TIME=$(date +%s)

while true; do
  # Try to collect a batch
  if ! collect_batch "$CURRENT_ID"; then
    if [[ -n "$START_TIME" && $(date +%s) -gt $((START_TIME + UPDATE_FREQUENCY * 2)) ]]; then
      log_error "No new files to process after two update cycles. Is fetch_osc.sh running?"
      exit 1
    fi
    SLEEP_TIME=$(calculate_sleep_time)
    log_message "No new files available, waiting $SLEEP_TIME s"
    sleep_with_interrupts "$SLEEP_TIME"
    continue
  fi

  START_TIME=
  LAST_UPDATE_WALL_CLOCK=$(date +%s)

  # Prepare processing directory
  PROCESS_DIR="$WORK_DIR/process_$BATCH_END"
  rm -rf "$PROCESS_DIR"
  mkdir -p "$PROCESS_DIR"

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
