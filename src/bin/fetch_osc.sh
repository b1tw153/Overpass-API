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
# Script: fetch_osc.sh
# Purpose: Downloads minutely OpenStreetMap change files from remote source
#          with atomic operations, integrity checking, and connection reuse
# ============================================================================

if [[ -z $3 ]]; then
{
  echo "Usage: $0 replicate_id source_url local_dir [sleep]"
  echo ""
  echo "  replicate_id: Starting replicate ID or 'auto' to resume from last fetch"
  echo "  source_url:   Remote replication source (e.g., https://planet.openstreetmap.org/replication/minute)"
  echo "  local_dir:    Local directory for downloaded files"
  echo "  sleep:        (Optional, ignored - kept for compatibility)"
  exit 0
}; fi

# ============================================================================
# CONFIGURATION
# ============================================================================

START_ID="$1"
SOURCE_URL="$2"
LOCAL_DIR="$3"

# Check for deprecated sleep parameter
if [[ -n "$4" ]]; then
  echo "WARNING: Sleep parameter is ignored (timing is now automatic)"
fi

# Download retry configuration
CURL_MAX_RETRIES=20       # Max download attempts before giving up
CURL_RETRY_DELAY=15       # Seconds between retry attempts
CURL_CONNECT_TIMEOUT=30   # Connection timeout in seconds
CURL_KEEPALIVE_TIME=20    # Seconds to retain previous connections
MAX_BATCH_SIZE=360        # Maximum OSC files per batch download

# Network outage handling
OUTAGE_RETRY_DELAY=60     # Seconds to wait during detected network outages
SOURCE_VERIFIED=false     # Flag to track if source URL has been verified

# Update timing configuration
EXPECTED_UPDATE_INTERVAL=51  # Seconds to wait before checking for next update
QUICK_RETRY_DELAY=1          # Seconds between quick retries
QUICK_RETRY_COUNT=10         # Number of quick retries before slow retry
SLOW_RETRY_DELAY=60          # Seconds between retries when updates delayed

# Timestamp tracking
LAST_UPDATE_WALL_CLOCK=      # Wall clock time when last update was downloaded

# Get execution directory (where binaries are located)
EXEC_DIR="$(dirname $0)/"
if [[ ! "${EXEC_DIR:0:1}" == "/" ]]; then
  EXEC_DIR="$(pwd)/$EXEC_DIR"
fi

# Get database directory from dispatcher
DB_DIR=$($EXEC_DIR/dispatcher --show-dir)

if [[ ! -d "$DB_DIR" ]]; then
  echo "ERROR: Database directory '$DB_DIR' does not exist"
  exit 1
fi

# Database state file (tracks what's been applied)
DB_STATE_FILE="$DB_DIR/replicate_id"

# Create local directory if needed
mkdir -p "$LOCAL_DIR"

# Log file
LOG_FILE="$LOCAL_DIR/fetch_osc.log"

# Fetch state tracking file
FETCH_STATE_FILE="$LOCAL_DIR/replicate_id"

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
# TIMING
# ============================================================================

calculate_sleep_time()
{
  if [[ -z "$LAST_UPDATE_WALL_CLOCK" ]]; then
    echo 15
    return
  fi
  
  local NOW=$(date +%s)
  local NEXT_CHECK=$((LAST_UPDATE_WALL_CLOCK + EXPECTED_UPDATE_INTERVAL))
  local SLEEP_TIME=$((NEXT_CHECK - NOW))
  
  if [[ $SLEEP_TIME -lt 0 ]]; then
    echo 0
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
# REMOTE STATE CHECKING
# ============================================================================

# Fetch and parse remote state.txt to get latest available replicate ID
# During network outages (after source has been verified), waits patiently
# Outputs the sequence number to stdout, or nothing on failure
get_latest_available_id()
{
  local REMOTE_STATE="$LOCAL_DIR/state.txt"
  
  while true; do
    rm -f "$REMOTE_STATE"
    curl -fsSL \
      --keepalive-time $CURL_KEEPALIVE_TIME \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --retry 3 \
      --retry-delay 5 \
      -o "$REMOTE_STATE" "$SOURCE_URL/state.txt" 2>/dev/null
    
    local CURL_EXIT=$?
    
    # If download succeeded, parse and return
    if [[ $CURL_EXIT -eq 0 && -s "$REMOTE_STATE" ]]; then
      local SEQ_LINE=$(grep -E '^sequenceNumber' "$REMOTE_STATE")
      if [[ -n "$SEQ_LINE" ]]; then
        # Parse the number (format is "sequenceNumber=12345")
        echo $((${SEQ_LINE:15} + 0))
        return 0
      fi
    fi
    
    # Download failed or file invalid
    # Check the SOURCE_VERIFIED flag (set in main loop, not here due to subshell)
    if [[ "$SOURCE_VERIFIED" == "true" ]]; then
      # Source was previously working - this is likely a network outage
      # Wait patiently and retry
      log_message "Unable to reach replication source (likely network outage), retrying in ${OUTAGE_RETRY_DELAY}s..."
      sleep_with_interrupts "$OUTAGE_RETRY_DELAY"
      # Continue loop to retry
    else
      # Source has never worked - might be a configuration error
      log_error "Cannot reach replication source: $SOURCE_URL"
      log_error "Please verify the source URL is correct"
      return 1
    fi
  done
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
# BATCH DOWNLOAD WITH CONNECTION REUSE
# ============================================================================

download_replicate_batch()
{
  local START=$1
  local END=$2
  local BATCH_COUNT=$(($END - $START))
  
  local URL_LIST=""
  local STATE_FILES=""
  local OSC_FILES=""
  
  for (( ID=$START+1; ID<=$END; ID++ )); do
    get_replicate_path $ID
    
    local REMOTE_BASE="$SOURCE_URL/$REPLICATE_PATH"
    local LOCAL_DIR_PATH="$LOCAL_DIR/$DIGIT1/$DIGIT2"
    mkdir -p "$LOCAL_DIR_PATH"
    
    local OSC_FILE="$LOCAL_DIR_PATH/$DIGIT3.osc.gz"
    local STATE_FILE_LOCAL="$LOCAL_DIR_PATH/$DIGIT3.state.txt"
    
    if ! verify_file "$STATE_FILE_LOCAL" "text"; then
      URL_LIST="$URL_LIST $REMOTE_BASE.state.txt"
      STATE_FILES="$STATE_FILES $STATE_FILE_LOCAL"
    fi
    
    if ! verify_file "$OSC_FILE" "gzip"; then
      URL_LIST="$URL_LIST $REMOTE_BASE.osc.gz"
      OSC_FILES="$OSC_FILES $OSC_FILE"
    fi
  done
  
  if [[ -z "$URL_LIST" ]]; then
    if [[ $BATCH_COUNT -eq 1 ]]; then
      log_message "Downloaded OSC file $END (cached)"
    else
      log_message "Downloaded $BATCH_COUNT OSC files (all cached)"
    fi
    return 0
  fi
  
  local TEMP_CONFIG="$LOCAL_DIR/curl_batch.txt"
  rm -f "$TEMP_CONFIG"
  
  local URL_ARRAY=($URL_LIST)
  local STATE_ARRAY=($STATE_FILES)
  local OSC_ARRAY=($OSC_FILES)
  local STATE_IDX=0
  local OSC_IDX=0
  
  for URL in "${URL_ARRAY[@]}"; do
    if [[ $URL == *.state.txt ]]; then
      echo "url = \"$URL\"" >> "$TEMP_CONFIG"
      echo "output = \"${STATE_ARRAY[$STATE_IDX]}.tmp\"" >> "$TEMP_CONFIG"
      STATE_IDX=$((STATE_IDX + 1))
    else
      echo "url = \"$URL\"" >> "$TEMP_CONFIG"
      echo "output = \"${OSC_ARRAY[$OSC_IDX]}.tmp\"" >> "$TEMP_CONFIG"
      OSC_IDX=$((OSC_IDX + 1))
    fi
  done
  
  # Download all files with connection reuse
  local CURL_ERROR_LOG="$LOCAL_DIR/curl_error_$.log"
  
  curl -fsSL \
    --keepalive-time $CURL_KEEPALIVE_TIME \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --retry "$CURL_MAX_RETRIES" \
    --retry-delay "$CURL_RETRY_DELAY" \
    --parallel \
    --parallel-max 4 \
    --config "$TEMP_CONFIG" 2>"$CURL_ERROR_LOG"
  
  local CURL_EXIT=$?
  rm -f "$TEMP_CONFIG"
  
  if [[ $CURL_EXIT -ne 0 ]]; then
    log_error "Batch download failed (exit code: $CURL_EXIT)"
    
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
    for (( ID=$START+1; ID<=$END; ID++ )); do
      get_replicate_path $ID
      rm -f "$LOCAL_DIR/$REPLICATE_PATH.state.txt.tmp"
      rm -f "$LOCAL_DIR/$REPLICATE_PATH.osc.gz.tmp"
    done
    return 1
  fi
  
  # Clean up error log if successful
  rm -f "$CURL_ERROR_LOG"
  
  local SUCCESS=1
  for (( ID=$START+1; ID<=$END; ID++ )); do
    get_replicate_path $ID
    local LOCAL_DIR_PATH="$LOCAL_DIR/$DIGIT1/$DIGIT2"
    local STATE_FILE="$LOCAL_DIR_PATH/$DIGIT3.state.txt"
    local OSC_FILE="$LOCAL_DIR_PATH/$DIGIT3.osc.gz"
    
    if [[ -f "$STATE_FILE.tmp" ]]; then
      if verify_file "$STATE_FILE.tmp" "text"; then
        mv "$STATE_FILE.tmp" "$STATE_FILE"
      else
        log_error "State file failed verification: ID $ID"
        rm -f "$STATE_FILE.tmp"
        SUCCESS=0
      fi
    fi
    
    if [[ -f "$OSC_FILE.tmp" ]]; then
      if verify_file "$OSC_FILE.tmp" "gzip"; then
        mv "$OSC_FILE.tmp" "$OSC_FILE"
      else
        log_error "OSC file failed verification: ID $ID"
        rm -f "$OSC_FILE.tmp"
        SUCCESS=0
      fi
    fi
  done
  
  if [[ $SUCCESS -eq 1 ]]; then
    if [[ $BATCH_COUNT -eq 1 ]]; then
      log_message "Downloaded OSC file $END"
    else
      log_message "Downloaded $BATCH_COUNT OSC files ($(($START + 1)) to $END)"
    fi
  else
    if [[ $BATCH_COUNT -eq 1 ]]; then
      log_error "File failed verification: OSC file $END"
    else
      log_error "Some files failed verification in batch $(($START + 1)) to $END"
    fi
  fi
  
  return $((1 - SUCCESS))
}

# ============================================================================
# FETCH STATE MANAGEMENT
# ============================================================================

read_fetch_state()
{
  if [[ -f "$FETCH_STATE_FILE" && -s "$FETCH_STATE_FILE" ]]; then
    cat "$FETCH_STATE_FILE"
  else
    echo "0"
  fi
}

read_db_state()
{
  if [[ -f "$DB_STATE_FILE" && -s "$DB_STATE_FILE" ]]; then
    cat "$DB_STATE_FILE"
  else
    echo "0"
  fi
}

update_fetch_state()
{
  local NEW_ID=$1
  echo "$NEW_ID" > "$FETCH_STATE_FILE.tmp"
  mv "$FETCH_STATE_FILE.tmp" "$FETCH_STATE_FILE"
}

# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

shutdown()
{
  log_message "Shutdown signal received, cleaning up..."
  rm -f "$LOCAL_DIR"/*.tmp
  log_message "Shutdown complete"
  exit 0
}

trap shutdown SIGTERM SIGINT

# ============================================================================
# MAIN EXECUTION
# ============================================================================

log_message "=========================================="
log_message "Starting fetch process"
log_message "Source: $SOURCE_URL"
log_message "Local directory: $LOCAL_DIR"
log_message "=========================================="

if [[ "$START_ID" == "auto" ]]; then
  # In auto mode, start from the database state (what's been applied)
  DB_ID=$(read_db_state)
  FETCH_ID=$(read_fetch_state)
  
  # Use whichever is higher (in case fetch was ahead when restarted)
  if [[ $FETCH_ID -gt $DB_ID ]]; then
    CURRENT_ID=$FETCH_ID
    log_message "Auto mode: resuming fetch from OSC file $CURRENT_ID (fetch ahead of apply)"
  else
    CURRENT_ID=$DB_ID
    log_message "Auto mode: resuming from OSC file $CURRENT_ID (database state)"
  fi
else
  CURRENT_ID=$START_ID
  log_message "Starting from OSC file $CURRENT_ID"
fi

while true; do
  MAX_AVAILABLE=$(get_latest_available_id)
  
  # get_latest_available_id will wait during outages if source was previously verified
  # If it returns without a value and source was never verified, there's a config error
  if [[ -z "$MAX_AVAILABLE" ]]; then
    log_error "Fatal: Cannot initialize - replication source unreachable"
    exit 1
  fi
  
  # Mark source as verified after first successful fetch
  if [[ "$SOURCE_VERIFIED" != "true" ]]; then
    SOURCE_VERIFIED=true
    log_message "Replication source verified and operational"
  fi
  
  if [[ $MAX_AVAILABLE -le $CURRENT_ID ]]; then
    SLEEP_TIME=$(calculate_sleep_time)
    
    if [[ $SLEEP_TIME -gt 0 ]]; then
      log_message "No new OSC files available (current: $CURRENT_ID), sleeping ${SLEEP_TIME}s"
      sleep_with_interrupts $SLEEP_TIME
      continue
    fi
    
    RETRY_COUNT=0
    while [[ $RETRY_COUNT -lt $QUICK_RETRY_COUNT ]]; do
      sleep_with_interrupts $QUICK_RETRY_DELAY
      RETRY_COUNT=$(($RETRY_COUNT + 1))
      
      MAX_AVAILABLE=$(get_latest_available_id)
      # get_latest_available_id will retry internally if SOURCE_VERIFIED=true
      # If it returns empty, there's a serious problem, but we should still
      # fall back to slow retry rather than exiting
      
      if [[ -n "$MAX_AVAILABLE" && $MAX_AVAILABLE -gt $CURRENT_ID ]]; then
        # New data found!
        break
      fi
      
      if [[ $RETRY_COUNT -lt $QUICK_RETRY_COUNT ]]; then
        log_message "Waiting for OSC file $((CURRENT_ID + 1)) (quick retry $RETRY_COUNT/$QUICK_RETRY_COUNT)"
      fi
    done
    
    # If still no new data after quick retries, fall back to slow retry
    if [[ -z "$MAX_AVAILABLE" || $MAX_AVAILABLE -le $CURRENT_ID ]]; then
      log_message "OSC file $((CURRENT_ID + 1)) not available, falling back to ${SLOW_RETRY_DELAY}s delays"
      sleep_with_interrupts $SLOW_RETRY_DELAY
      continue
    fi
  fi
  
  # Determine batch size
  BATCH_END=$CURRENT_ID
  for (( TEST_ID=$CURRENT_ID+1; TEST_ID<=$MAX_AVAILABLE && TEST_ID<=$CURRENT_ID+$MAX_BATCH_SIZE; TEST_ID++ )); do
    BATCH_END=$TEST_ID
  done
  
  BATCH_COUNT=$(($BATCH_END - $CURRENT_ID))
  if [[ $BATCH_COUNT -eq 1 ]]; then
    log_message "Fetching OSC file $BATCH_END"
  else
    log_message "Fetching $BATCH_COUNT OSC files ($(($CURRENT_ID + 1)) to $BATCH_END)"
  fi
  
  if download_replicate_batch $CURRENT_ID $BATCH_END; then
    LAST_UPDATE_WALL_CLOCK=$(date +%s)
    update_fetch_state $BATCH_END
    CURRENT_ID=$BATCH_END
  else
    log_error "Batch download failed, retrying"
    sleep_with_interrupts 60
  fi
done
