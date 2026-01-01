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

if [[ -z $3 ]]; then
{
  echo "Usage: $0 replicate_dir start_id --meta=(attic|yes|no)"
  echo ""
  echo "  replicate_dir: Directory containing downloaded replicate files"
  echo "  start_id:      Starting replicate ID or 'auto' to resume from database state"
  echo "  --meta:        Metadata handling mode (attic=full history, yes=metadata, no=current only)"
  exit 0
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
MAX_BATCH_SIZE=360          # Maximum OSC files per batch (6 hours)

# Timestamp tracking
EXPECTED_UPDATE_INTERVAL=57 # Seconds to wait before checking for next update
LAST_UPDATE_WALL_CLOCK=     # Wall clock time when last update was collected

# Get execution directory
EXEC_DIR="$(dirname $0)/"
if [[ ! ${EXEC_DIR:0:1} == "/" ]]; then
  EXEC_DIR="$(pwd)/$EXEC_DIR"
fi

# Convert replicate dir to absolute path
if [[ ! ${REPLICATE_DIR:0:1} == "/" ]]; then
  REPLICATE_DIR="$(pwd)/$REPLICATE_DIR"
fi

# Get database directory
DB_DIR=$($EXEC_DIR/dispatcher --show-dir)

if [[ ! -d "$DB_DIR" ]]; then
  echo "ERROR: Database directory '$DB_DIR' does not exist"
  exit 1
fi

# State file
STATE_FILE="$DB_DIR/replicate_id"

# Log file
LOG_FILE="$DB_DIR/apply_osc_to_db.log"

# Working directory for decompressed files
WORK_DIR=$(mktemp -d /tmp/osm-3s_update_XXXXXX)
mkdir -p "$WORK_DIR"

# ============================================================================
# LOGGING
# ============================================================================

log_message()
{
  echo "$(date -u '+%F %T'): $1" | tee -a "$LOG_FILE"
}

log_error()
{
  echo "$(date -u '+%F %T'): ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

read_current_state()
{
  if [[ -f "$STATE_FILE" && -s "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    echo "0"
  fi
}

update_state()
{
  local NEW_ID=$1
  echo "$NEW_ID" > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# ============================================================================
# PATH CONVERSION
# ============================================================================

get_replicate_path()
{
  local ID=$1
  printf -v DIGIT3 %03u $(($ID % 1000))
  local ARG=$(($ID / 1000))
  printf -v DIGIT2 %03u $(($ARG % 1000))
  ARG=$(($ARG / 1000))
  printf -v DIGIT1 %03u $ARG
  REPLICATE_PATH="$DIGIT1/$DIGIT2/$DIGIT3"
}

# ============================================================================
# BATCH COLLECTION
# ============================================================================

collect_batch()
{
  local START=$1
  local CURRENT=$(($START + 1))

  BATCH_END=$START

  # Find contiguous downloaded files up to MAX_BATCH_SIZE
  for (( ID=$CURRENT; ID<=$START+$MAX_BATCH_SIZE; ID++ )); do
    get_replicate_path $ID

    local OSC_FILE="$REPLICATE_DIR/$REPLICATE_PATH.osc.gz"
    local STATE_FILE_LOCAL="$REPLICATE_DIR/$REPLICATE_PATH.state.txt"

    if [[ -f "$OSC_FILE" && -f "$STATE_FILE_LOCAL" ]]; then
      BATCH_END=$ID
    else
      break
    fi
  done

  if [[ $BATCH_END -le $START ]]; then
    return 1
  fi

  local COUNT=$(($BATCH_END - $START))
  if [[ $COUNT -eq 1 ]]; then
      log_message "Collected one OSC file: $BATCH_END"
    else
      log_message "Collected batch: $START to $BATCH_END ($COUNT OSC files)"
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
  local COUNT=$(($END - $START))
  local OUT_DIR="$3"

  mkdir -p "$OUT_DIR"

  if [[ $COUNT -eq 1 ]]; then
    log_message "Decompressing OSC file: $END"
  else
    log_message "Decompressing batch: $START to $END ($COUNT OSC files)"
  fi

  for (( ID=$START+1; ID<=$END; ID++ )); do
    get_replicate_path $ID

    local OSC_GZ="$REPLICATE_DIR/$REPLICATE_PATH.osc.gz"

    if [[ ! -f "$OSC_GZ" ]]; then
      log_error "Missing file: $OSC_GZ"
      return 1
    fi

    printf -v OUT_FILE %09u $ID

    gunzip <"$OSC_GZ" >"$OUT_DIR/$OUT_FILE.osc"

    if [[ $? -ne 0 ]]; then
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
  get_replicate_path $ID

  local STATE_FILE_LOCAL="$REPLICATE_DIR/$REPLICATE_PATH.state.txt"

  local TIMESTAMP_LINE=""
  local WAIT_COUNT=0
  while [[ -z "$TIMESTAMP_LINE" && $WAIT_COUNT -lt 10 ]]; do
    TIMESTAMP_LINE=$(grep "^timestamp" <"$STATE_FILE_LOCAL" 2>/dev/null)
    if [[ -z "$TIMESTAMP_LINE" ]]; then
      sleep_with_interrupts 1
      WAIT_COUNT=$(($WAIT_COUNT + 1))
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

  cd "$EXEC_DIR"

  local SUCCESS=0
  local RETRY_COUNT=0
  local MAX_RETRIES=5

  while [[ $SUCCESS -eq 0 && $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    ./update_from_dir --osc-dir="$OSC_DIR" --version="$DATA_VERSION" $META --flush-size=0
    local EXITCODE=$?

    if [[ $EXITCODE -eq 0 ]]; then
      SUCCESS=1
    elif [[ $EXITCODE -eq 15 ]]; then
      log_message "Received SIGTERM, shutting down gracefully"
      exit 15
    else
      RETRY_COUNT=$(($RETRY_COUNT + 1))
      log_error "update_from_dir failed (exit code: $EXITCODE), retry $RETRY_COUNT/$MAX_RETRIES"

      if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
        sleep_with_interrupts 60
      fi
    fi
  done

  cd - >/dev/null

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

  local NOW=$(date +%s)
  local NEXT_CHECK=$((LAST_UPDATE_WALL_CLOCK + EXPECTED_UPDATE_INTERVAL))
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
  sleep $1 &
  wait $!
}

# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

shutdown()
{
  log_message "Shutdown signal received, cleaning up..."

  if [[ -n "$CHILD_PID" && $CHILD_PID -gt 0 ]]; then
    kill $CHILD_PID 2>/dev/null
  fi

  rm -rf "$WORK_DIR"

  log_message "Shutdown complete"
  exit 0
}

trap shutdown SIGTERM SIGINT

# ============================================================================
# MAIN EXECUTION
# ============================================================================

log_message "=========================================="
log_message "Starting apply process"
log_message "Replicate directory: $REPLICATE_DIR"
log_message "Metadata mode: $META_ARG"
log_message "=========================================="

if [[ "$START_ID" == "auto" ]]; then
  CURRENT_ID=$(read_current_state)
  log_message "Auto mode: resuming from OSC file $CURRENT_ID"
else
  CURRENT_ID=$START_ID
  log_message "Starting from OSC file $CURRENT_ID"
fi

# Run database migration
log_message "Running database migration"
cd "$EXEC_DIR"
./migrate_database --migrate &
CHILD_PID=$!
wait "$CHILD_PID"
CHILD_PID=
cd - >/dev/null

# Delete old temp files
log_message "Deleting old temporary files and directories"
rm -rf /tmp/osm-3s_update_*

while true; do
  # Try to collect a batch
  if ! collect_batch $CURRENT_ID; then
    SLEEP_TIME=$(calculate_sleep_time)
    log_message "No new OSC files available, waiting $SLEEP_TIME s"
    sleep_with_interrupts $SLEEP_TIME
    continue
  fi

  LAST_UPDATE_WALL_CLOCK=$(date +%s)

  # Prepare processing directory
  PROCESS_DIR="$WORK_DIR/process_$BATCH_END"
  rm -rf "$PROCESS_DIR"
  mkdir -p "$PROCESS_DIR"

  # Decompress batch
  if ! prepare_batch $CURRENT_ID $BATCH_END "$PROCESS_DIR"; then
    log_error "Failed to prepare batch, skipping"
    rm -rf "$PROCESS_DIR"
    sleep_with_interrupts 60
    continue
  fi

  # Get timestamp
  if ! get_timestamp $BATCH_END; then
    log_error "Failed to get timestamp, skipping batch"
    rm -rf "$PROCESS_DIR"
    sleep_with_interrupts 60
    continue
  fi

  # Apply batch
  if ! apply_batch "$PROCESS_DIR"; then
    log_error "Failed to apply batch, will retry"
    rm -rf "$PROCESS_DIR"
    sleep_with_interrupts 60
    continue
  fi

  # Success - update state
  update_state $BATCH_END
  CURRENT_ID=$BATCH_END

  log_message "Successfully applied batch up to OSC file $CURRENT_ID"

  # Clean up
  rm -rf "$PROCESS_DIR"
done
