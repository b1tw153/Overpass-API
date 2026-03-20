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
# Script: fetch_osc_and_apply.sh
# Purpose: Downloads and applies OSM change files in a single process
# ============================================================================

usage()
{
  cat << EOF
Usage: $0 source_url

  source_url   Replication source URL
               (e.g., https://planet.openstreetmap.org/replication/minute)

This script combines fetching and applying OSM change files in a single process.
It downloads files directly into memory without a local cache directory.

Environment variables:
  OVERPASS_UPDATE_FREQUENCY     Update interval in seconds (default: 60)
  FETCH_OSC_UPDATE_TRIM         Offset added to the update interval when scheduling the
                                next check; use a negative value to compensate for
                                processing overhead (default: -6)
  FETCH_OSC_MAX_BATCH_SIZE      Maximum number of OSC files per batch (default: 1440)
  APPLY_OSC_MAX_BATCH_MB        Maximum uncompressed batch size in MB (default: 64)
  FETCH_OSC_CONNECT_TIMEOUT     Connection timeout in seconds (default: 30)
  FETCH_OSC_KEEPALIVE_TIME      Seconds to keep idle connections alive (default: 20)
  FETCH_OSC_MAX_RETRIES         Maximum download attempts per file before giving up (default: 10)
  FETCH_OSC_RETRY_DELAY         Seconds between retry attempts (default: 15)
  FETCH_OSC_SPEED_LIMIT         Minimum download speed in bytes/sec; 0 to disable (default: 1024)
  FETCH_OSC_SPEED_TIME          Time in seconds over which to check minimum speed (default: 30)
  APPLY_OSC_APPLY_MAX_RETRIES   Maximum apply attempts per batch before giving up (default: 5)
EOF
}

if [[ -z "$1" ]]; then
  usage
  exit 1
fi

if [[ -n "$2" ]]; then
  echo "ERROR: Too many arguments"
  usage
  exit 1
fi

SOURCE_URL="$1"

# ============================================================================
# CONFIGURATION
# ============================================================================

# Update timing configuration
UPDATE_FREQUENCY=${OVERPASS_UPDATE_FREQUENCY:-60}
UPDATE_TRIM=${FETCH_OSC_UPDATE_TRIM:--6}

# Batch configuration
MAX_BATCH_COUNT=${FETCH_OSC_MAX_BATCH_SIZE:-1440}
MAX_BATCH_MB=${APPLY_OSC_MAX_BATCH_MB:-64}

# Download configuration
CURL_CONNECT_TIMEOUT=${FETCH_OSC_CONNECT_TIMEOUT:-30}
CURL_KEEPALIVE_TIME=${FETCH_OSC_KEEPALIVE_TIME:-20}
CURL_MAX_RETRIES=${FETCH_OSC_MAX_RETRIES:-10}
CURL_RETRY_DELAY=${FETCH_OSC_RETRY_DELAY:-15}
CURL_SPEED_LIMIT=${FETCH_OSC_SPEED_LIMIT:-1024}
CURL_SPEED_TIME=${FETCH_OSC_SPEED_TIME:-30}

# Apply configuration
APPLY_MAX_RETRIES=${APPLY_OSC_APPLY_MAX_RETRIES:-5}

# Network state tracking
SOURCE_VERIFIED=false

# Timestamp tracking
LAST_UPDATE_WALL_CLOCK=

# Child process tracking
CHILD_PID=

# Get execution directory
EXEC_DIR="$(realpath "$(dirname "$0")")"

# Get database directory
DB_DIR=$("$EXEC_DIR/dispatcher" --show-dir)
DB_DIR="$(realpath "$DB_DIR")"

if [[ ! -d "$DB_DIR" ]]; then
  echo "ERROR: Database directory '$DB_DIR' does not exist"
  exit 1
fi

if [[ ! -f "$DB_DIR/replicate_id" || ! -s "$DB_DIR/replicate_id" ]]; then
  echo "ERROR: $DB_DIR/replicate_id is not a regular file or is empty"
  exit 1
fi

if ! touch "$DB_DIR/replicate_id"; then
  echo "ERROR: $DB_DIR/replicate_id is not writeable"
  exit 1
fi

# State file
STATE_FILE="$DB_DIR/replicate_id"

# Log file
LOG_FILE="$DB_DIR/fetch_osc_and_apply.log"

# PID file
PID_FILE="$DB_DIR/apply_osc.pid"
echo "$$" > "$PID_FILE" || { echo "ERROR: Unable to write PID file: $PID_FILE"; exit 1; }

# Temp directories for this session
TEMP_SOURCE_DIR=
TEMP_TARGET_DIR=

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

die()
{
  cleanup_temp_dirs
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
# CONFIGURATION VALIDATION
# ============================================================================

verify_globals()
{
  if [[ ! "$UPDATE_FREQUENCY" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid OVERPASS_UPDATE_FREQUENCY: $UPDATE_FREQUENCY"
    die 1
  fi

  if [[ ! "$UPDATE_TRIM" =~ ^-?[0-9]+$ ]]; then
    log_error "Invalid FETCH_OSC_UPDATE_TRIM: $UPDATE_TRIM"
    die 1
  fi

  if [[ ! "$MAX_BATCH_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid FETCH_OSC_MAX_BATCH_SIZE: $MAX_BATCH_COUNT"
    die 1
  fi

  if [[ ! "$MAX_BATCH_MB" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid APPLY_OSC_MAX_BATCH_MB: $MAX_BATCH_MB"
    die 1
  fi

  if [[ ! "$CURL_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid FETCH_OSC_CONNECT_TIMEOUT: $CURL_CONNECT_TIMEOUT"
    die 1
  fi

  if [[ ! "$CURL_KEEPALIVE_TIME" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid FETCH_OSC_KEEPALIVE_TIME: $CURL_KEEPALIVE_TIME"
    die 1
  fi

  if [[ ! "$CURL_MAX_RETRIES" =~ ^[0-9]+$ ]]; then
    log_error "Invalid FETCH_OSC_MAX_RETRIES: $CURL_MAX_RETRIES"
    die 1
  fi

  if [[ ! "$CURL_RETRY_DELAY" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid FETCH_OSC_RETRY_DELAY: $CURL_RETRY_DELAY"
    die 1
  fi

  if [[ ! "$CURL_SPEED_LIMIT" =~ ^[0-9]+$ ]]; then
    log_error "Invalid FETCH_OSC_SPEED_LIMIT: $CURL_SPEED_LIMIT"
    die 1
  fi

  if [[ ! "$CURL_SPEED_TIME" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid FETCH_OSC_SPEED_TIME: $CURL_SPEED_TIME"
    die 1
  fi

  if [[ ! "$APPLY_MAX_RETRIES" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid APPLY_OSC_APPLY_MAX_RETRIES: $APPLY_MAX_RETRIES"
    die 1
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
# REMOTE STATE CHECKING
# ============================================================================

get_latest_available_id()
{
  local REMOTE_STATE="$TEMP_SOURCE_DIR/state.txt"
  local REMOTE_STATE_TMP="$REMOTE_STATE.tmp"

  local CURL_ERROR_LOG="$TEMP_SOURCE_DIR/state.curl_err"

  while true; do
    rm -f "$REMOTE_STATE_TMP"

    curl -fsSL \
      --keepalive-time "$CURL_KEEPALIVE_TIME" \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --retry 3 \
      --retry-delay 5 \
      --retry-all-errors \
      -o "$REMOTE_STATE_TMP" "$SOURCE_URL/state.txt" 2>"$CURL_ERROR_LOG"

    local CURL_EXIT=$?

    if [[ $CURL_EXIT -eq 0 && -s "$REMOTE_STATE_TMP" ]]; then
      local SEQ_LINE
      SEQ_LINE=$(grep -E '^sequenceNumber=[1-9][0-9]*$' "$REMOTE_STATE_TMP")
      if [[ -n "$SEQ_LINE" ]]; then
        mv "$REMOTE_STATE_TMP" "$REMOTE_STATE"
        echo "$((${SEQ_LINE#*=} + 0))"
        return 0
      else
        log_error "Downloaded state.txt missing sequenceNumber"
        rm -f "$REMOTE_STATE_TMP"
      fi
    else
      if [[ -s "$CURL_ERROR_LOG" ]]; then
        log_error "Curl error output:"
        while IFS= read -r LINE; do
          log_error "  $LINE"
        done < "$CURL_ERROR_LOG"
      fi
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
# FILE DOWNLOAD
# ============================================================================

download_file()
{
  local URL="$1"
  local OUTPUT="$2"
  local TMP_FILE="$OUTPUT.tmp"
  local CURL_ERROR_LOG="$OUTPUT.curl_err"

  curl -fsSL \
    --keepalive-time "$CURL_KEEPALIVE_TIME" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --retry "$CURL_MAX_RETRIES" \
    --retry-delay "$CURL_RETRY_DELAY" \
    --retry-all-errors \
    --speed-limit "$CURL_SPEED_LIMIT" \
    --speed-time "$CURL_SPEED_TIME" \
    -o "$TMP_FILE" "$URL" 2>"$CURL_ERROR_LOG"

  local CURL_EXIT=$?

  if [[ $CURL_EXIT -ne 0 ]]; then
    rm -f "$TMP_FILE"
    if [[ -s "$CURL_ERROR_LOG" ]]; then
      log_error "Curl error output:"
      while IFS= read -r LINE; do
        log_error "  $LINE"
      done < "$CURL_ERROR_LOG"
    fi
    rm -f "$CURL_ERROR_LOG"
    return $CURL_EXIT
  fi

  rm -f "$CURL_ERROR_LOG"

  if [[ ! -s "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
    return 1
  fi

  mv "$TMP_FILE" "$OUTPUT"
  log_message "Downloaded $URL to $OUTPUT"
  return 0
}

# ============================================================================
# BATCH COLLECTION
# ============================================================================

collect_minute_diffs()
{
  local MAX_AVAILABLE=$1

  BATCH_END=$CURRENT_ID

  # Determine potential batch end (limited by count and availability)
  local POTENTIAL_END=$((CURRENT_ID + MAX_BATCH_COUNT))
  if [[ $POTENTIAL_END -gt $MAX_AVAILABLE ]]; then
    POTENTIAL_END=$MAX_AVAILABLE
  fi

  if [[ $POTENTIAL_END -le $CURRENT_ID ]]; then
    return 1
  fi

  # Download, decompress, and check size one file at a time
  local ID
  local TARGET_FILE
  local STATE_URL
  local OSC_URL
  local STATE_FILE_LOCAL
  local OSC_FILE_LOCAL
  local OSC_FILE_DECOMPRESSED
  local CURRENT_SIZE_MB

  for (( ID=CURRENT_ID+1; ID<=POTENTIAL_END; ID++ )); do
    # Check size before downloading next file (like master branch)
    CURRENT_SIZE_MB=$(du -m "$TEMP_TARGET_DIR" 2>/dev/null | awk '{print $1}')
    if [[ ${CURRENT_SIZE_MB:-0} -gt $MAX_BATCH_MB ]]; then
      break
    fi

    get_replicate_path "$ID"
    printf -v TARGET_FILE %09u "$ID"

    STATE_URL="$SOURCE_URL/$REPLICATE_PATH.state.txt"
    OSC_URL="$SOURCE_URL/$REPLICATE_PATH.osc.gz"
    STATE_FILE_LOCAL="$TEMP_SOURCE_DIR/$TARGET_FILE.state.txt"
    OSC_FILE_LOCAL="$TEMP_SOURCE_DIR/$TARGET_FILE.osc.gz"
    OSC_FILE_DECOMPRESSED="$TEMP_TARGET_DIR/$TARGET_FILE.osc"

    # Download state file
    if ! download_file "$STATE_URL" "$STATE_FILE_LOCAL"; then
      log_error "Failed to download state file for $ID"
      break
    fi

    # Download OSC file
    if ! download_file "$OSC_URL" "$OSC_FILE_LOCAL"; then
      log_error "Failed to download OSC file for $ID"
      break
    fi

    # Decompress
    if ! gunzip <"$OSC_FILE_LOCAL" >"$OSC_FILE_DECOMPRESSED" 2>/dev/null; then
      log_error "Failed to decompress OSC file for $ID"
      break
    fi

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

  # timestamp=YYYY-MM-DDTHH\:MM\:SSZ
  TIMESTAMP_LINE=$(grep -E "^timestamp=[0-9\-]{10}T[0-9\\\:]{10}Z" <"$STATE_FILE_LOCAL" 2>/dev/null)

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
    CHILD_PID=$!
    wait "$CHILD_PID"
    local EXITCODE=$?
    CHILD_PID=

    case $EXITCODE in
      0)
        SUCCESS=1
        ;;
      3)
        log_error "update_from_dir failed due to dispatcher error (exit code: $EXITCODE)"
        return 1
        ;;
      15)
        log_message "Received SIGTERM in update_from_dir, shutting down gracefully"
        shutdown 143
        ;;
      126|127)
        log_error "update_from_dir not found or not executable (exit code: $EXITCODE)"
        die 1
        ;;
      134)
        log_error "Received SIGABRT (exit code: $EXITCODE) from update_from_dir, shutting down"
        log_error "Database may be corrupt; verify or restore from backup before resuming updates"
        shutdown $EXITCODE
        ;;
      *)
        if [[ $EXITCODE -ge 128 && $EXITCODE -le 165 ]]; then
          log_message "update_from_dir terminated by signal (exit code: $EXITCODE)"
          shutdown $EXITCODE
        else
          RETRY_COUNT=$((RETRY_COUNT + 1))
          if [[ $RETRY_COUNT -lt $APPLY_MAX_RETRIES ]]; then
            log_error "update_from_dir failed (exit code: $EXITCODE), attempt $((RETRY_COUNT + 1))/$APPLY_MAX_RETRIES"
            sleep_with_interrupts "$UPDATE_FREQUENCY"
          fi
        fi
        ;;
    esac
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
  if ! { echo "$NEW_ID" > "$STATE_FILE.tmp"; }; then
    log_error "Failed to write new state to temporary file"
    die 1
  fi
  if ! { mv "$STATE_FILE.tmp" "$STATE_FILE"; }; then
    log_error "Failed to update state file"
    die 1
  fi
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

  # Wait for migrate_database or update_from_dir to complete
  if [[ -n "$CHILD_PID" ]]; then
    wait "$CHILD_PID"
  fi

  cleanup_temp_dirs
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

verify_globals

echo >> "$LOG_FILE"
log_message "Starting fetch and apply from $SOURCE_URL"

# This may be legacy code for an unused directory
mkdir -p "$DB_DIR/augmented_diffs/"

CURRENT_ID=$(($(read_current_state) + 0))

if [[ $CURRENT_ID -lt 0 ]]; then
  log_error "Invalid replicate_id: $CURRENT_ID"
  die 1
fi

pushd "$EXEC_DIR" > /dev/null || die 1

# Run database migration
log_message "Running database migration"
./migrate_database --migrate &
CHILD_PID=$!
wait "$CHILD_PID"
EXIT_CODE=$?
CHILD_PID=
if [[ $EXIT_CODE -ne 0 ]]; then
  log_error "Database migration failed"
  die 1
fi

while true; do
  log_message "Updating from $CURRENT_ID"

  TEMP_SOURCE_DIR=$(mktemp -d /tmp/osm-3s_update_XXXXXX)
  if [[ ! -d "$TEMP_SOURCE_DIR" ]]; then
    log_error "Unable to create temporary source directory"
    die 1
  fi

  TEMP_TARGET_DIR=$(mktemp -d /tmp/osm-3s_update_XXXXXX)
  if [[ ! -d "$TEMP_TARGET_DIR" ]]; then
    log_error "Unable to create temporary target directory"
    die 1
  fi

  MAX_AVAILABLE=$(get_latest_available_id)

  if [[ -z "$MAX_AVAILABLE" ]]; then
    log_error "Fatal: Cannot reach replication source"
    die 1
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
