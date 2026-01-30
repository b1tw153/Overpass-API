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
# Script: fetch_osc_and_apply.sh
# Purpose: Downloads and applies OSM change files in a single process
# ============================================================================

# Ensure the script is its own process group leader
PGID=$(ps -o pgid= $$ 2>/dev/null | tr -d ' ')
if [[ -z "$PGID" ]]; then
  echo "ERROR: Unable to determine process group ID"
  exit 1
fi
if [[ $$ -ne "$PGID" ]]; then
  exec setsid "$0" "$@"
  echo "ERROR: Unable to create new process group with setsid"
  exit 1
fi

if [[ -z "$1" ]]; then
{
  echo "Usage: $0 diff_url"
  echo "Error: Set the URL to get diffs from (like https://planet.osm.org/replication/minute)"
  exit 0
}; fi

SOURCE_URL="$1"

# ============================================================================
# CONFIGURATION
# ============================================================================

# Update timing configuration
UPDATE_FREQUENCY=${OVERPASS_UPDATE_FREQUENCY:-60}
UPDATE_TRIM=${FETCH_OSC_UPDATE_TRIM:--6}

# Batch configuration
MAX_BATCH_COUNT=${FETCH_OSC_MAX_BATCH_SIZE:-1440}
MAX_BATCH_MB=${APPLY_OSC_TO_DB_MAX_BATCH_MB:-64}

# Download configuration
CURL_CONNECT_TIMEOUT=${FETCH_OSC_CONNECT_TIMEOUT:-30}
CURL_KEEPALIVE_TIME=${FETCH_OSC_KEEPALIVE_TIME:-20}
CURL_MAX_RETRIES=${FETCH_OSC_MAX_RETRIES:-10}
CURL_RETRY_DELAY=${FETCH_OSC_RETRY_DELAY:-15}
CURL_PARALLEL_MAX=${FETCH_OSC_PARALLEL_MAX:-4}
CURL_SPEED_LIMIT=${FETCH_OSC_SPEED_LIMIT:-1024}
CURL_SPEED_TIME=${FETCH_OSC_SPEED_TIME:-30}

# Apply configuration
APPLY_MAX_RETRIES=${APPLY_OSC_TO_DB_APPLY_MAX_RETRIES:-5}

# Network state tracking
SOURCE_VERIFIED=false

# Timestamp tracking
LAST_UPDATE_WALL_CLOCK=

# Get execution directory
EXEC_DIR="$(dirname "$0")/"
if [[ ! "${EXEC_DIR:0:1}" == "/" ]]; then
  EXEC_DIR="$(pwd)/$EXEC_DIR"
fi

# Get database directory
DB_DIR=$("$EXEC_DIR/dispatcher" --show-dir)

if [[ ! -d "$DB_DIR" ]]; then
  echo "ERROR: Database directory '$DB_DIR' does not exist"
  exit 1
fi

if [[ ! -s "$DB_DIR/replicate_id" ]]; then
  echo "ERROR: $DB_DIR/replicate_id does not exist"
  exit 1
fi

# State file
STATE_FILE="$DB_DIR/replicate_id"

# Log file
LOG_FILE="$DB_DIR/fetch_osc_and_apply.log"

# Temp directories for this session
TEMP_SOURCE_DIR=
TEMP_TARGET_DIR=

# ============================================================================
# LOGGING
# ============================================================================

log_message()
{
  echo "$(date -u '+%F %T'): $1" >> "$LOG_FILE"
}

log_error()
{
  echo "$(date -u '+%F %T'): ERROR: $1" >> "$LOG_FILE"
}

# ============================================================================
# CONFIGURATION VALIDATION
# ============================================================================

verify_globals()
{
  if [[ ! "$UPDATE_FREQUENCY" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid OVERPASS_UPDATE_FREQUENCY: $UPDATE_FREQUENCY"
    exit 1
  fi

  if [[ ! "$UPDATE_TRIM" =~ ^-?[0-9]+$ ]]; then
    log_error "Invalid FETCH_OSC_UPDATE_TRIM: $UPDATE_TRIM"
    exit 1
  fi

  if [[ ! "$MAX_BATCH_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid FETCH_OSC_MAX_BATCH_SIZE: $MAX_BATCH_COUNT"
    exit 1
  fi

  if [[ ! "$MAX_BATCH_MB" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid APPLY_OSC_TO_DB_MAX_BATCH_MB: $MAX_BATCH_MB"
    exit 1
  fi

  if [[ ! "$CURL_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid FETCH_OSC_CONNECT_TIMEOUT: $CURL_CONNECT_TIMEOUT"
    exit 1
  fi

  if [[ ! "$CURL_KEEPALIVE_TIME" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid FETCH_OSC_KEEPALIVE_TIME: $CURL_KEEPALIVE_TIME"
    exit 1
  fi

  if [[ ! "$CURL_MAX_RETRIES" =~ ^[0-9]+$ ]]; then
    log_error "Invalid FETCH_OSC_MAX_RETRIES: $CURL_MAX_RETRIES"
    exit 1
  fi

  if [[ ! "$CURL_RETRY_DELAY" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid FETCH_OSC_RETRY_DELAY: $CURL_RETRY_DELAY"
    exit 1
  fi

  if [[ ! "$CURL_PARALLEL_MAX" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid FETCH_OSC_PARALLEL_MAX: $CURL_PARALLEL_MAX"
    exit 1
  fi

  if [[ ! "$CURL_SPEED_LIMIT" =~ ^[0-9]+$ ]]; then
    log_error "Invalid FETCH_OSC_SPEED_LIMIT: $CURL_SPEED_LIMIT"
    exit 1
  fi

  if [[ ! "$CURL_SPEED_TIME" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid FETCH_OSC_SPEED_TIME: $CURL_SPEED_TIME"
    exit 1
  fi

  if [[ ! "$APPLY_MAX_RETRIES" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid APPLY_OSC_TO_DB_APPLY_MAX_RETRIES: $APPLY_MAX_RETRIES"
    exit 1
  fi
}

# ============================================================================
# TIMING
# ============================================================================

calculate_sleep_time()
{
  if [[ -z "$LAST_UPDATE_WALL_CLOCK" ]]; then
    echo 10
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
# PATH CONVERSION
# ============================================================================

get_replicate_path()
{
  local ID=$1
  local ARG

  printf -v DIGIT3 %03u $((ID % 1000))
  ARG=$((ID / 1000))
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
# REMOTE STATE CHECKING
# ============================================================================

get_latest_available_id()
{
  local REMOTE_STATE="$TEMP_SOURCE_DIR/state.txt"
  local REMOTE_STATE_TMP="$REMOTE_STATE.tmp"

  while true; do
    rm -f "$REMOTE_STATE_TMP"

    curl -fsSL \
      --keepalive-time "$CURL_KEEPALIVE_TIME" \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --retry 3 \
      --retry-delay 5 \
      --retry-all-errors \
      -o "$REMOTE_STATE_TMP" "$SOURCE_URL/state.txt" 2>/dev/null

    local CURL_EXIT=$?

    if [[ $CURL_EXIT -eq 0 && -s "$REMOTE_STATE_TMP" ]]; then
      if verify_file "$REMOTE_STATE_TMP" "text"; then
        mv "$REMOTE_STATE_TMP" "$REMOTE_STATE"
        local SEQ_LINE
        SEQ_LINE=$(grep -E '^sequenceNumber=' "$REMOTE_STATE")
        if [[ -n "$SEQ_LINE" ]]; then
          echo "$((${SEQ_LINE#*=} + 0))"
          return 0
        fi
      else
        log_error "Downloaded state.txt failed validation"
        rm -f "$REMOTE_STATE_TMP"
      fi
    else
      rm -f "$REMOTE_STATE_TMP"
    fi

    if [[ "$SOURCE_VERIFIED" == "true" ]]; then
      log_message "Unable to reach replication source, retrying in ${UPDATE_FREQUENCY}s..."
      sleep_with_interrupts "$UPDATE_FREQUENCY"
    else
      log_error "Cannot reach replication source: $SOURCE_URL"
      return 1
    fi
  done
}

# ============================================================================
# BATCH DOWNLOAD
# ============================================================================

download_batch()
{
  local START=$1
  local END=$2
  local BATCH_COUNT=$((END - START))

  local URL_ARRAY=()
  local OUTPUT_ARRAY=()
  local TYPE_ARRAY=()
  local ID
  local TARGET_FILE
  local TEMP_CONFIG
  local CURL_EXIT
  local IDX

  # Build arrays of URLs and output files
  for (( ID=START+1; ID<=END; ID++ )); do
    get_replicate_path "$ID"
    printf -v TARGET_FILE %09u "$ID"

    # State file
    URL_ARRAY+=("$SOURCE_URL/$REPLICATE_PATH.state.txt")
    OUTPUT_ARRAY+=("$TEMP_SOURCE_DIR/$TARGET_FILE.state.txt")
    TYPE_ARRAY+=("text")

    # OSC file
    URL_ARRAY+=("$SOURCE_URL/$REPLICATE_PATH.osc.gz")
    OUTPUT_ARRAY+=("$TEMP_SOURCE_DIR/$TARGET_FILE.osc.gz")
    TYPE_ARRAY+=("gzip")
  done

  if [[ ${#URL_ARRAY[@]} -eq 0 ]]; then
    return 0
  fi

  # Create curl config file
  TEMP_CONFIG="$TEMP_SOURCE_DIR/curl_batch.txt"
  rm -f "$TEMP_CONFIG"

  for (( IDX=0; IDX<${#URL_ARRAY[@]}; IDX++ )); do
    echo "url = \"${URL_ARRAY[$IDX]}\"" >> "$TEMP_CONFIG"
    echo "output = \"${OUTPUT_ARRAY[$IDX]}.tmp\"" >> "$TEMP_CONFIG"
  done

  # Download all files with connection reuse and parallel transfers
  local CURL_ERROR_LOG="$TEMP_SOURCE_DIR/curl_error_$$.log"

  curl -fsSL \
    --keepalive-time "$CURL_KEEPALIVE_TIME" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --retry "$CURL_MAX_RETRIES" \
    --retry-delay "$CURL_RETRY_DELAY" \
    --retry-all-errors \
    --parallel \
    --parallel-max "$CURL_PARALLEL_MAX" \
    --parallel-immediate \
    --speed-limit "$CURL_SPEED_LIMIT" \
    --speed-time "$CURL_SPEED_TIME" \
    --config "$TEMP_CONFIG" 2>"$CURL_ERROR_LOG"

  CURL_EXIT=$?
  rm -f "$TEMP_CONFIG"

  if [[ $CURL_EXIT -ne 0 ]]; then
    log_error "Batch download failed (curl exit code: $CURL_EXIT)"

    # Log curl error details if available
    if [[ -s "$CURL_ERROR_LOG" ]]; then
      log_error "Curl error output:"
      while IFS= read -r line; do
        log_error "  $line"
      done < "$CURL_ERROR_LOG"
    fi

    # Provide context for common error codes
    case $CURL_EXIT in
      6)  log_error "Exit 6: Could not resolve host" ;;
      7)  log_error "Exit 7: Failed to connect to host" ;;
      16) log_error "Exit 16: HTTP/2 protocol error (connection reset or framing issue)" ;;
      18) log_error "Exit 18: Partial file transfer" ;;
      22) log_error "Exit 22: HTTP response code indicated failure" ;;
      23) log_error "Exit 23: Write error" ;;
      28) log_error "Exit 28: Operation timeout" ;;
      35) log_error "Exit 35: SSL connect error" ;;
      52) log_error "Exit 52: Empty reply from server" ;;
      55) log_error "Exit 55: Failed sending network data" ;;
      56) log_error "Exit 56: Failed receiving network data" ;;
    esac

    rm -f "$CURL_ERROR_LOG"

    # Clean up temp files
    for (( IDX=0; IDX<${#OUTPUT_ARRAY[@]}; IDX++ )); do
      rm -f "${OUTPUT_ARRAY[$IDX]}.tmp"
    done
    return 1
  fi

  # Clean up error log on success
  rm -f "$CURL_ERROR_LOG"

  # Verify and move files
  local SUCCESS=1
  for (( IDX=0; IDX<${#OUTPUT_ARRAY[@]}; IDX++ )); do
    local TMP_FILE="${OUTPUT_ARRAY[$IDX]}.tmp"
    local FINAL_FILE="${OUTPUT_ARRAY[$IDX]}"
    local FILE_TYPE="${TYPE_ARRAY[$IDX]}"

    if [[ -f "$TMP_FILE" ]]; then
      if verify_file "$TMP_FILE" "$FILE_TYPE"; then
        mv "$TMP_FILE" "$FINAL_FILE"
      else
        log_error "File failed verification: $FINAL_FILE"
        rm -f "$TMP_FILE"
        SUCCESS=0
      fi
    else
      log_error "File not downloaded: $FINAL_FILE"
      SUCCESS=0
    fi
  done

  if [[ $SUCCESS -eq 1 ]]; then
    if [[ $BATCH_COUNT -eq 1 ]]; then
      log_message "Downloaded $END"
    else
      log_message "Downloaded $BATCH_COUNT files ($((START + 1)) to $END)"
    fi
    return 0
  else
    return 1
  fi
}

# ============================================================================
# BATCH COLLECTION
# ============================================================================

collect_minute_diffs()
{
  local MAX_AVAILABLE=$1
  local MAX_BATCH_BYTES=$((MAX_BATCH_MB * 1024 * 1024))

  BATCH_END=$CURRENT_ID

  # Determine potential batch end (limited by count and availability)
  local POTENTIAL_END=$((CURRENT_ID + MAX_BATCH_COUNT))
  if [[ $POTENTIAL_END -gt $MAX_AVAILABLE ]]; then
    POTENTIAL_END=$MAX_AVAILABLE
  fi

  if [[ $POTENTIAL_END -le $CURRENT_ID ]]; then
    return 1
  fi

  # Download all files in the potential batch
  if ! download_batch "$CURRENT_ID" "$POTENTIAL_END"; then
    return 1
  fi

  # Decompress and check cumulative size, trimming batch if needed
  local BATCH_SIZE_BYTES=0
  local ID
  local TARGET_FILE
  local OSC_FILE_LOCAL
  local OSC_FILE_DECOMPRESSED
  local FILE_SIZE

  for (( ID=CURRENT_ID+1; ID<=POTENTIAL_END; ID++ )); do
    printf -v TARGET_FILE %09u "$ID"

    OSC_FILE_LOCAL="$TEMP_SOURCE_DIR/$TARGET_FILE.osc.gz"
    OSC_FILE_DECOMPRESSED="$TEMP_TARGET_DIR/$TARGET_FILE.osc"

    # Decompress
    if ! gunzip <"$OSC_FILE_LOCAL" >"$OSC_FILE_DECOMPRESSED" 2>/dev/null; then
      log_error "Failed to decompress OSC file for $ID"
      break
    fi

    # Get file size
    FILE_SIZE=$(stat -c%s "$OSC_FILE_DECOMPRESSED" 2>/dev/null || stat -f%z "$OSC_FILE_DECOMPRESSED" 2>/dev/null)

    if [[ -z "$FILE_SIZE" ]]; then
      log_error "Cannot determine file size for $ID"
      rm -f "$OSC_FILE_DECOMPRESSED"
      break
    fi

    # Check if adding this file would exceed batch size limit
    local NEW_BATCH_SIZE=$((BATCH_SIZE_BYTES + FILE_SIZE))
    if [[ $BATCH_SIZE_BYTES -gt 0 && $NEW_BATCH_SIZE -gt $MAX_BATCH_BYTES ]]; then
      # Remove this file, we've hit the size limit
      rm -f "$OSC_FILE_DECOMPRESSED"
      break
    fi

    BATCH_SIZE_BYTES=$NEW_BATCH_SIZE
    BATCH_END=$ID
  done

  if [[ $BATCH_END -gt $CURRENT_ID ]]; then
    return 0
  else
    return 1
  fi
}

# ============================================================================
# TIMESTAMP EXTRACTION
# ============================================================================

get_data_version()
{
  local ID=$1
  printf -v TARGET_FILE %09u "$ID"

  local STATE_FILE_LOCAL="$TEMP_SOURCE_DIR/$TARGET_FILE.state.txt"
  local TIMESTAMP_LINE

  TIMESTAMP_LINE=$(grep "^timestamp" <"$STATE_FILE_LOCAL" 2>/dev/null)

  if [[ -z "$TIMESTAMP_LINE" ]]; then
    log_error "Could not extract timestamp from state file for $ID"
    return 1
  fi

  DATA_VERSION=${TIMESTAMP_LINE:10}
  return 0
}

# ============================================================================
# BATCH APPLICATION
# ============================================================================

apply_minute_diffs()
{
  local OSC_DIR="$1"
  local SUCCESS=0
  local RETRY_COUNT=0

  while [[ $SUCCESS -eq 0 && $RETRY_COUNT -lt $APPLY_MAX_RETRIES ]]; do
    ./update_from_dir --osc-dir="$OSC_DIR" --version="$DATA_VERSION" --flush-size=0 &
    wait $!
    local EXITCODE=$?

    if [[ $EXITCODE -eq 0 ]]; then
      SUCCESS=1
    elif [[ $EXITCODE -eq 3 ]]; then
      log_error "update_from_dir failed due to dispatcher error (exit code: $EXITCODE)"
      return 1
    elif [[ $EXITCODE -eq 126 || $EXITCODE -eq 127 ]]; then
      log_error "update_from_dir not found or not executable (exit code: $EXITCODE)"
      return 1
    elif [[ $EXITCODE -ge 128 && $EXITCODE -le 165 ]]; then
      log_message "update_from_dir terminated by signal (exit code: $EXITCODE)"
      shutdown $EXITCODE
    else
      RETRY_COUNT=$((RETRY_COUNT + 1))
      if [[ $RETRY_COUNT -lt $APPLY_MAX_RETRIES ]]; then
        log_error "update_from_dir failed (exit code: $EXITCODE), attempt $((RETRY_COUNT + 1))/$APPLY_MAX_RETRIES"
        sleep_with_interrupts "$UPDATE_FREQUENCY"
      fi
    fi
  done

  if [[ $SUCCESS -eq 0 ]]; then
    log_error "Failed to apply batch after $APPLY_MAX_RETRIES attempts"
    return 1
  fi

  return 0
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
# CLEANUP
# ============================================================================

cleanup_temp_dirs()
{
  if [[ -n "$TEMP_TARGET_DIR" && -d "$TEMP_TARGET_DIR" ]]; then
    rm -f "$TEMP_TARGET_DIR"/*
    rmdir "$TEMP_TARGET_DIR" 2>/dev/null || true
  fi
  if [[ -n "$TEMP_SOURCE_DIR" && -d "$TEMP_SOURCE_DIR" ]]; then
    rm -f "$TEMP_SOURCE_DIR"/*
    rmdir "$TEMP_SOURCE_DIR" 2>/dev/null || true
  fi
  TEMP_SOURCE_DIR=
  TEMP_TARGET_DIR=
}

# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

shutdown()
{
  local EXIT_CODE=${1:-143}

  log_message "Shutdown signal received, cleaning up..."

  # Temporarily ignore signals to prevent recursion
  trap '' SIGTERM SIGINT SIGHUP

  # Kill all processes in the process group except ourselves
  kill -TERM -- -$$ 2>/dev/null || true

  # Wait for children to finish
  wait 2>/dev/null || true

  cleanup_temp_dirs

  log_message "Shutdown complete"
  exit "$EXIT_CODE"
}

trap 'shutdown 143' SIGTERM
trap 'shutdown 130' SIGINT
trap 'shutdown 129' SIGHUP

# ============================================================================
# MAIN EXECUTION
# ============================================================================

verify_globals

echo >> "$LOG_FILE"
log_message "Starting fetch and apply from $SOURCE_URL"

mkdir -p "$DB_DIR/augmented_diffs/"

CURRENT_ID=$(($(read_current_state) + 0))

if [[ $CURRENT_ID -le 0 ]]; then
  log_error "Invalid replicate_id: $CURRENT_ID"
  exit 1
fi

pushd "$EXEC_DIR" > /dev/null || exit 1

# Run database migration
log_message "Running database migration"
./migrate_database --migrate &
wait $!

while true; do
  log_message "Updating from $CURRENT_ID"

  TEMP_SOURCE_DIR=$(mktemp -d /tmp/osm-3s_update_XXXXXX)
  TEMP_TARGET_DIR=$(mktemp -d /tmp/osm-3s_update_XXXXXX)

  MAX_AVAILABLE=$(get_latest_available_id)

  if [[ -z "$MAX_AVAILABLE" ]]; then
    log_error "Fatal: Cannot reach replication source"
    cleanup_temp_dirs
    exit 1
  fi

  if [[ "$SOURCE_VERIFIED" != "true" ]]; then
    SOURCE_VERIFIED=true
    log_message "Replication source verified"
  fi

  if [[ $MAX_AVAILABLE -le $CURRENT_ID ]]; then
    cleanup_temp_dirs
    SLEEP_TIME=$(calculate_sleep_time)
    log_message "No new files available, sleeping ${SLEEP_TIME}s"
    sleep_with_interrupts "$SLEEP_TIME"
    continue
  fi

  if collect_minute_diffs "$MAX_AVAILABLE"; then
    BATCH_COUNT=$((BATCH_END - CURRENT_ID))
    log_message "Collected $BATCH_COUNT file(s), updating to $BATCH_END"

    if get_data_version "$BATCH_END"; then
      if apply_minute_diffs "$TEMP_TARGET_DIR"; then
        update_state "$BATCH_END"
        CURRENT_ID=$BATCH_END
        LAST_UPDATE_WALL_CLOCK=$(date +%s)
        log_message "Update complete: $CURRENT_ID"
      else
        log_error "Failed to apply batch"
      fi
    else
      log_error "Failed to get data version"
    fi
  else
    SLEEP_TIME=$(calculate_sleep_time)
    log_message "No files collected, sleeping ${SLEEP_TIME}s"
    sleep_with_interrupts "$SLEEP_TIME"
  fi

  cleanup_temp_dirs
done
