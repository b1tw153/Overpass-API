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
# Script: fetch_osc.sh
# Purpose: Downloads OpenStreetMap replication files from remote source
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
  exit 1
}; fi

# ============================================================================
# CONFIGURATION
# ============================================================================

START_ID="$1"
SOURCE_URL="$2"
LOCAL_DIR="$3"

# Validate replicate_id: must be a positive integer or 'auto'
if [[ "$START_ID" != "auto" && ! "$START_ID" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: Invalid replicate_id '$START_ID': must be a positive integer or 'auto'"
  exit 1
fi

# Validate source_url: must be an HTTP or HTTPS URL
if [[ ! "$SOURCE_URL" =~ ^https?:// ]]; then
  echo "ERROR: Invalid source_url '$SOURCE_URL': must start with http:// or https://"
  exit 1
fi

# Validate local_dir: must be usable as a directory
if ! mkdir -p "$LOCAL_DIR" 2>/dev/null; then
  echo "ERROR: local_dir '$LOCAL_DIR' is not writable or cannot be created"
  exit 1
fi

# Check for deprecated sleep parameter
if [[ -n "$4" ]]; then
  echo "WARNING: Sleep parameter is ignored (timing is now automatic)"
fi

# Download tool configuration
if which "curl" > /dev/null 2>&1; then
  PREFERRED_DOWNLOAD_TOOL="curl"
elif which "wget" > /dev/null 2>&1; then
  PREFERRED_DOWNLOAD_TOOL="wget"
else
  echo "ERROR: Neither curl nor wget is available"
  exit 1
fi

DOWNLOAD_TOOL=${FETCH_OSC_DOWNLOAD_TOOL:-$PREFERRED_DOWNLOAD_TOOL} # Either "wget" or "curl"

# Update timing configuration
UPDATE_FREQUENCY=${OVERPASS_UPDATE_FREQUENCY:-60}       # Frequency of updates in seconds
UPDATE_TRIM=${FETCH_OSC_UPDATE_TRIM:--6}                # Seconds to adjust expected update time
QUICK_RETRY_DELAY=${FETCH_OSC_QUICK_RETRY_DELAY:-1}     # Seconds between quick retries
QUICK_RETRY_COUNT=${FETCH_OSC_QUICK_RETRY_COUNT:-10}    # Number of quick retries before slow retry

# Batch configuration
MAX_BATCH_SIZE=${FETCH_OSC_MAX_BATCH_SIZE:-360}         # Maximum OSC files per batch download
MAX_BATCH_TIME=${FETCH_OSC_MAX_BATCH_TIME:-86400}       # Maximum time span of OSC files per batch (in seconds)

# Download configuration
MAX_RETRIES=${FETCH_OSC_MAX_RETRIES:-20}                # Max download attempts before giving up
RETRY_DELAY=${FETCH_OSC_RETRY_DELAY:-15}                # Seconds between retry attempts
CONNECT_TIMEOUT=${FETCH_OSC_CONNECT_TIMEOUT:-30}        # Connection timeout in seconds
KEEPALIVE_TIME=${FETCH_OSC_KEEPALIVE_TIME:-20}          # Seconds to retain previous connections
PARALLEL_MAX=${FETCH_OSC_PARALLEL_MAX:-4}               # Maximum parallel connections for batch downloads
PARALLEL_MODE=${FETCH_OSC_PARALLEL_MODE:-"multiplexed"} # Either "immediate" or "multiplexed"
SPEED_LIMIT=${FETCH_OSC_SPEED_LIMIT:-1024}              # Minimum download speed in bytes/sec
SPEED_TIME=${FETCH_OSC_SPEED_TIME:-30}                  # Time in seconds to check for speed limit

# Suggested environment variables for hourly replication
# OVERPASS_UPDATE_FREQUENCY=3600
# FETCH_OSC_UPDATE_TRIM=-60
# FETCH_OSC_QUICK_RETRY_DELAY=60
# FETCH_OSC_QUICK_RETRY_COUNT=10
# FETCH_OSC_MAX_BATCH_SIZE=24
# FETCH_OSC_RETRY_DELAY=60
# FETCH_OSC_CONNECT_TIMEOUT=60
# FETCH_OSC_KEEPALIVE_TIME=120
# FETCH_OSC_SPEED_LIMIT=10240
# FETCH_OSC_SPEED_TIME=60

# Suggested environment variables for daily replication
# OVERPASS_UPDATE_FREQUENCY=86400
# FETCH_OSC_UPDATE_TRIM=-600
# FETCH_OSC_QUICK_RETRY_DELAY=600
# FETCH_OSC_QUICK_RETRY_COUNT=6
# FETCH_OSC_MAX_BATCH_SIZE=1
# FETCH_OSC_RETRY_DELAY=300
# FETCH_OSC_CONNECT_TIMEOUT=120
# FETCH_OSC_KEEPALIVE_TIME=300
# FETCH_OSC_PARALLEL_MAX=1
# FETCH_OSC_SPEED_LIMIT=102400
# FETCH_OSC_SPEED_TIME=120

SOURCE_VERIFIED=false  # Flag to track if source URL has been verified

LAST_UPDATE_TIME=      # Time when last update was downloaded

# Get execution directory
EXEC_DIR="$(dirname "$0")/"
if [[ ! "${EXEC_DIR:0:1}" == "/" ]]; then
  EXEC_DIR="$(pwd)/$EXEC_DIR"
fi

# Get database directory from dispatcher
DB_DIR=$("$EXEC_DIR/dispatcher" --show-dir)

if [[ ! -d "$DB_DIR" ]]; then
  echo "ERROR: Database directory '$DB_DIR' does not exist"
  exit 1
fi

# Database state file
DB_STATE_FILE="$DB_DIR/replicate_id"

# Log file
LOG_FILE="$LOCAL_DIR/fetch_osc.log"

# Fetch state file
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
# VARIABLES
# ============================================================================
verify_globals()
{
  if [[ ! "$UPDATE_FREQUENCY" =~ ^[1-9][0-9]+$ ]]; then
    echo "ERROR: Invalid UPDATE_FREQUENCY: $UPDATE_FREQUENCY"
    exit 1
  fi

  if [[ UPDATE_FREQUENCY -ne 60 && UPDATE_FREQUENCY -ne 3600 && UPDATE_FREQUENCY -ne 86400 ]]; then
    echo "WARNING: Unexpected UPDATE_FREQUENCY: $UPDATE_FREQUENCY (expected: 60, 3600, 86400)"
  fi

  if [[ ! "$UPDATE_TRIM" =~ ^-?[0-9]+$ ]]; then
    echo "ERROR: Invalid UPDATE_TRIM: $UPDATE_TRIM"
    exit 1
  fi

  local ABS_TRIM=${UPDATE_TRIM#-}
  if [[ $ABS_TRIM -gt $((UPDATE_FREQUENCY / 10)) ]]; then
    echo "WARNING: UPDATE_TRIM ($UPDATE_TRIM) is large relative to UPDATE_FREQUENCY ($UPDATE_FREQUENCY)"
  fi

  if [[ ! "$QUICK_RETRY_DELAY" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Invalid QUICK_RETRY_DELAY: $QUICK_RETRY_DELAY"
    exit 1
  fi

  if [[ $QUICK_RETRY_DELAY -gt $((UPDATE_FREQUENCY / 10)) ]]; then
    echo "WARNING: QUICK_RETRY_DELAY ($QUICK_RETRY_DELAY) is large relative to UPDATE_FREQUENCY ($UPDATE_FREQUENCY)"
  fi

  if [[ ! "$QUICK_RETRY_COUNT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid QUICK_RETRY_COUNT: $QUICK_RETRY_COUNT"
    exit 1
  fi

  if [[ ! "$MAX_BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Invalid MAX_BATCH_SIZE: $MAX_BATCH_SIZE"
    exit 1
  fi

  local MAX_POSSIBLE_BATCH_TIME=$((MAX_BATCH_SIZE * UPDATE_FREQUENCY))
  if [[ $MAX_POSSIBLE_BATCH_TIME -gt 86400 ]]; then
    echo "WARNING: MAX_BATCH_SIZE ($MAX_BATCH_SIZE) with UPDATE_FREQUENCY ($UPDATE_FREQUENCY) exceeds one day"
  fi

  if [[ ! "$MAX_BATCH_TIME" =~ ^[1-9][0-9]+$ ]]; then
    echo "ERROR: Invalid MAX_BATCH_TIME: $MAX_BATCH_TIME"
    exit 1
  fi

  # verify that MAX_BATCH_TIME is at least UPDATE_FREQUENCY
  if [[ $MAX_BATCH_TIME -lt $UPDATE_FREQUENCY ]]; then
    echo "ERROR: MAX_BATCH_TIME ($MAX_BATCH_TIME) must be at least UPDATE_FREQUENCY ($UPDATE_FREQUENCY)"
    exit 1
  fi

  # verify that MAX_BATCH_TIME is less than one day
  if [[ $MAX_BATCH_TIME -gt 86400 ]]; then
    echo "WARNING: MAX_BATCH_TIME ($MAX_BATCH_TIME) exceeds one day"
  fi

  if [[ ! "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid MAX_RETRIES: $MAX_RETRIES"
    exit 1
  fi

  if [[ ! "$RETRY_DELAY" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Invalid RETRY_DELAY: $RETRY_DELAY"
    exit 1
  fi

  if [[ ! "$CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Invalid CONNECT_TIMEOUT: $CONNECT_TIMEOUT"
    exit 1
  fi

  if [[ ! "$KEEPALIVE_TIME" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Invalid KEEPALIVE_TIME: $KEEPALIVE_TIME"
    exit 1
  fi

  if [[ ! "$PARALLEL_MAX" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Invalid PARALLEL_MAX: $PARALLEL_MAX"
    exit 1
  fi

  if [[ ! "$PARALLEL_MODE" =~ ^(immediate|multiplexed)$ ]]; then
    echo "ERROR: Invalid PARALLEL_MODE: $PARALLEL_MODE"
    echo "PARALLEL_MODE must be either \"immediate\" or \"multiplexed\""
    exit 1
  fi

  if [[ ! "$SPEED_LIMIT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid SPEED_LIMIT: $SPEED_LIMIT"
    exit 1
  fi

  if [[ ! "$SPEED_TIME" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Invalid SPEED_TIME: $SPEED_TIME"
    exit 1
  fi

  if [[ ! "$DOWNLOAD_TOOL" =~ ^(curl|wget)$ ]]; then
    echo "ERROR: Invalid DOWNLOAD_TOOL: $DOWNLOAD_TOOL"
    echo "DOWNLOAD_TOOL must be either \"curl\" or \"wget\""
    exit 1
  fi
}

# ============================================================================
# TIMING
# ============================================================================

calculate_sleep_time()
{
  if [[ -z "$LAST_UPDATE_TIME" ]]; then
    echo $((UPDATE_FREQUENCY / 4))
    return
  fi
  
  local NOW
  NOW=$(date +%s)
  local NEXT_CHECK=$((LAST_UPDATE_TIME + UPDATE_FREQUENCY + UPDATE_TRIM))
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
  sleep "$1" &
  wait $!
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
    if ! grep -qE '^sequenceNumber=[1-9][0-9]*$' "$FILE" 2>/dev/null; then
      return 1
    fi
    if ! grep -qE '^timestamp=[0-9\-]{10}T[0-9\\\:]{10}Z$' "$FILE" 2>/dev/null; then
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
  local REMOTE_STATE="$LOCAL_DIR/state.txt"
  local REMOTE_STATE_TMP="$REMOTE_STATE.tmp"

  while true; do
    rm -f "$REMOTE_STATE_TMP"

    if [[ $DOWNLOAD_TOOL = "curl" ]] ; then
      curl -fsSL \
        --keepalive-time "$KEEPALIVE_TIME" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --retry 3 \
        --retry-delay 5 \
        --retry-all-errors \
        -o "$REMOTE_STATE_TMP" \
        "$SOURCE_URL/state.txt" \
        2>/dev/null
    elif [[ $DOWNLOAD_TOOL = "wget" ]]; then
      wget \
        --quiet \
        --timeout="$CONNECT_TIMEOUT" \
        --tries=3 \
        --waitretry=5 \
        --retry-connrefused \
        --output-document="$REMOTE_STATE_TMP" \
        "$SOURCE_URL/state.txt" \
        2>/dev/null
    else
      log_error "Invalid DOWNLOAD_TOOL: $DOWNLOAD_TOOL"
    fi

    local TOOL_EXIT=$?

    if [[ $TOOL_EXIT -eq 0 && -s "$REMOTE_STATE_TMP" ]]; then
      if verify_file "$REMOTE_STATE_TMP" "text"; then
        local SEQ_LINE
        SEQ_LINE=$(grep -E '^sequenceNumber=[1-9][0-9]*$' "$REMOTE_STATE_TMP")
        if [[ -n "$SEQ_LINE" ]]; then
          mv "$REMOTE_STATE_TMP" "$REMOTE_STATE" || log_error "Unable to update $REMOTE_STATE"
          echo $((${SEQ_LINE#*=} + 0))
          return 0
        fi
      else
        log_error "Downloaded state.txt failed validation (may be HTML error page or corrupted data)"
        rm -f "$REMOTE_STATE_TMP"
      fi
    fi

    # Download failed or file invalid
    if [[ "$SOURCE_VERIFIED" == "true" ]]; then
      # Source was previously working - wait patiently and retry
      log_message "Unable to reach replication source (likely network outage), retrying in ${UPDATE_FREQUENCY}s..."
      sleep_with_interrupts "$UPDATE_FREQUENCY"
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

get_path()
{
  local ID=$1
  local ARG

  DIGIT3=$(printf '%03u' $((ID % 1000)))
  ARG=$((ID / 1000))
  DIGIT2=$(printf '%03u' $((ARG % 1000)))
  ARG=$((ARG / 1000))
  DIGIT1=$(printf '%03u' $ARG)
  URL_PATH="$DIGIT1/$DIGIT2/$DIGIT3"
}

# ============================================================================
# DOWNLOAD HELPERS
# ============================================================================

download_batch_with_curl()
{
  local URL
  local INDEX
  local CURL_CONFIG
  local CURL_ERROR_LOG
  local PARALLEL_IMMEDIATE
  local CURL_EXIT
  local LINE

  CURL_CONFIG="$LOCAL_DIR/curl_batch.txt"
  rm -f "$CURL_CONFIG"

  INDEX=0

  for URL in "${URL_ARRAY[@]}"; do
    echo "url = \"$URL\"" >> "$CURL_CONFIG"
    echo "output = \"${FILE_ARRAY[$INDEX]}.tmp\"" >> "$CURL_CONFIG"
    ((++INDEX))
  done
  
  CURL_ERROR_LOG="$LOCAL_DIR/curl_error_$$.log"

  PARALLEL_IMMEDIATE=
  [[ $PARALLEL_MODE = "immediate" ]] && PARALLEL_IMMEDIATE="--parallel-immediate"

  curl -fsSL \
    --keepalive-time "$KEEPALIVE_TIME" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --retry "$MAX_RETRIES" \
    --retry-delay "$RETRY_DELAY" \
    --parallel \
    --parallel-max "$PARALLEL_MAX" \
    $PARALLEL_IMMEDIATE \
    --speed-limit "$SPEED_LIMIT" \
    --speed-time "$SPEED_TIME" \
    --config "$CURL_CONFIG" \
    2>"$CURL_ERROR_LOG"

  CURL_EXIT=$?
  rm -f "$CURL_CONFIG"
  
  if [[ $CURL_EXIT -ne 0 ]]; then
    log_error "Batch download failed (curl exit code: $CURL_EXIT)"
    
    if [[ -s "$CURL_ERROR_LOG" ]]; then
      log_error "Curl error output:"
      while IFS= read -r LINE; do
        log_error "  $LINE"
      done < "$CURL_ERROR_LOG"
    fi
    
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
  fi
  
  rm -f "$CURL_ERROR_LOG"
}

download_batch_with_wget()
{
  local WGET_ERROR_LOG
  local INDEX
  local URL
  local WGET_EXIT
  local LINE

  WGET_ERROR_LOG="$LOCAL_DIR/wget_error_$$.log"
  rm -f "$WGET_ERROR_LOG"

  INDEX=0

  for URL in "${URL_ARRAY[@]}"; do
    wget \
      --quiet \
      --tries="$MAX_RETRIES" \
      --waitretry="$RETRY_DELAY" \
      --timeout="$CONNECT_TIMEOUT" \
      --output-document="${FILE_ARRAY[$INDEX]}.tmp" \
      "$URL" \
      2>"$WGET_ERROR_LOG"

    WGET_EXIT=$?

    if [[ $WGET_EXIT -ne 0 ]]; then
      log_error "Batch download failed (wget exit code: $WGET_EXIT)"
      
      if [[ -s "$WGET_ERROR_LOG" ]]; then
        log_error "Wget error output:"
        while IFS= read -r LINE; do
          log_error "  $LINE"
        done < "$WGET_ERROR_LOG"
      fi
      
      case $WGET_EXIT in
        1) log_error "Exit 1: Generic wget failure" ;;
        2) log_error "Exit 2: Parse error (likely script bug)" ;;
        3) log_error "Exit 3: File I/O error" ;;
        4) log_error "Exit 4: Network failure" ;;
        5) log_error "Exit 5: TLS verification failure" ;;
        6) log_error "Exit 6: Username/password authentication failure" ;;
        7) log_error "Exit 7: Protocol error" ;;
        8) log_error "Exit 8: Server error response" ;;
      esac

      break
    fi

    ((++INDEX))
  done

  rm -f "$WGET_ERROR_LOG"
}

# ============================================================================
# BATCH DOWNLOAD
# ============================================================================

download_batch()
{
  local START=$1
  local END=$2
  local BATCH_COUNT=$((END - START))

  local ID
  local REMOTE_BASE
  local DIR_PATH
  local FILE
  local URL_ARRAY=()
  local FILE_ARRAY=()
  local CACHED_COUNT
  local TYPE
  local SUCCESS

  CACHED_COUNT=0
  for (( ID=START+1; ID<=END; ID++ )); do
    get_path "$ID"

    REMOTE_BASE="$SOURCE_URL/$URL_PATH"
    DIR_PATH="$LOCAL_DIR/$DIGIT1/$DIGIT2"
    if ! mkdir -p "$DIR_PATH"; then
    {
      log_error "Fatal error: unable to create $DIR_PATH directory."
      exit 1
    }; fi

    FILE="$DIR_PATH/$DIGIT3.state.txt"
    if ! verify_file "$FILE" "text"; then
      URL_ARRAY+=("$REMOTE_BASE.state.txt")
      FILE_ARRAY+=("$FILE")
    else
      ((++CACHED_COUNT))
    fi

    FILE="$DIR_PATH/$DIGIT3.osc.gz"
    if ! verify_file "$FILE" "gzip"; then
      URL_ARRAY+=("$REMOTE_BASE.osc.gz")
      FILE_ARRAY+=("$FILE")
    else
      ((++CACHED_COUNT))
    fi
  done

  [[ $CACHED_COUNT -gt 0 ]] && log_message "Verified ($((CACHED_COUNT * 50 / BATCH_COUNT))%) of files already cached"

  if [[ ${#URL_ARRAY[@]} -eq 0 ]]; then
    if [[ $BATCH_COUNT -eq 1 ]]; then
      log_message "Downloaded $END (cached)"
    else
      log_message "Downloaded $BATCH_COUNT files (all cached)"
    fi
    return 0
  fi

  if [[ $DOWNLOAD_TOOL = "curl" ]]; then
    download_batch_with_curl
  elif [[ $DOWNLOAD_TOOL = "wget" ]]; then
    download_batch_with_wget
  fi

  SUCCESS=1

  for FILE in "${FILE_ARRAY[@]}"; do
    if [[ -f "$FILE.tmp" ]]; then
      if [[ $FILE =~ .*\.state\.txt$ ]]; then
        TYPE="text"
      elif [[ $FILE =~ .*\.osc\.gz$ ]]; then
        TYPE="gzip"
      fi
      if verify_file "$FILE.tmp" "$TYPE"; then
        if ! mv "$FILE.tmp" "$FILE"; then
          log_error "Unable to save $FILE"
          rm -f "$FILE.tmp"
          SUCCESS=0
        fi
      else
        log_error "File failed verification: $FILE"
        rm -f "$FILE.tmp"
        SUCCESS=0
      fi
    else
      SUCCESS=0
    fi
  done

  if [[ $SUCCESS -eq 1 ]]; then
    if [[ $BATCH_COUNT -eq 1 ]]; then
      log_message "Downloaded $END"
    else
      log_message "Downloaded $BATCH_COUNT files ($((START + 1)) to $END)"
    fi
  else
    if [[ $BATCH_COUNT -eq 1 ]]; then
      log_error "File failed verification: OSC file $END"
    else
      log_error "Some files failed verification in batch $((START + 1)) to $END"
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
  mv "$FETCH_STATE_FILE.tmp" "$FETCH_STATE_FILE" || log_error "Unable to update $FETCH_STATE_FILE"
}

# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

shutdown()
{
  local EXIT_CODE=$1

  log_message "Shutdown signal received, cleaning up..."
  if [[ -n "$LOCAL_DIR" && -d "$LOCAL_DIR" ]]; then
    find "$LOCAL_DIR" -name "*.tmp" -type f -delete
  fi
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

log_message "Starting fetch from $SOURCE_URL to $LOCAL_DIR"

if [[ "$START_ID" == "auto" ]]; then
  if [[ ! -f "$DB_STATE_FILE" || ! -s "$DB_STATE_FILE" ]]; then
    echo "ERROR: $DB_STATE_FILE does not exist and start set to auto"
    echo "Auto mode requires an existing replicate_id to resume from"
    echo "Use an explicit replicate ID instead of 'auto' to start fresh"
    exit 1
  fi

  DB_ID=$(read_db_state)
  FETCH_ID=$(read_fetch_state)

  if [[ $DB_ID -eq 0 && $FETCH_ID -eq 0 ]]; then
    echo "ERROR: Both database and fetch state are 0 in auto mode"
    echo "Cannot determine where to resume from"
    exit 1
  fi

  if [[ $FETCH_ID -gt $DB_ID ]]; then
    CURRENT_ID=$FETCH_ID
    log_message "Auto mode: resuming from $CURRENT_ID (fetch ahead of apply)"
  else
    CURRENT_ID=$DB_ID
    log_message "Auto mode: resuming from $CURRENT_ID (database state)"
  fi
else
  # In explicit mode, START_ID is the first file to download
  # Set CURRENT_ID to the file before it (last file we "already have")
  CURRENT_ID=$((START_ID - 1))
  log_message "Starting from $START_ID"
fi

while true; do
  MAX_AVAILABLE=$(get_latest_available_id)
  
  # get_latest_available_id will wait during outages if source was previously verified
  # If it returns without a value and source was never verified, there's a config error
  if [[ -z "$MAX_AVAILABLE" ]]; then
    echo "ERROR: Cannot initialize - replication source unreachable or invalid"
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
      log_message "No new files available (current: $CURRENT_ID), sleeping ${SLEEP_TIME}s"
      sleep_with_interrupts "$SLEEP_TIME"
      continue
    fi
    
    RETRY_COUNT=0
    while [[ $RETRY_COUNT -lt $QUICK_RETRY_COUNT ]]; do
      sleep_with_interrupts "$QUICK_RETRY_DELAY"
      ((++RETRY_COUNT))
      
      MAX_AVAILABLE=$(get_latest_available_id)
      
      if [[ -n "$MAX_AVAILABLE" && $MAX_AVAILABLE -gt $CURRENT_ID ]]; then
        break
      fi
      
      if [[ $RETRY_COUNT -lt $QUICK_RETRY_COUNT ]]; then
        log_message "Waiting for file $((CURRENT_ID + 1)) (quick retry $RETRY_COUNT/$QUICK_RETRY_COUNT)"
      fi
    done
    
    # If still no new data after quick retries, fall back to slow retry
    if [[ -z "$MAX_AVAILABLE" || $MAX_AVAILABLE -le $CURRENT_ID ]]; then
      log_message "File $((CURRENT_ID + 1)) not available, falling back to ${UPDATE_FREQUENCY}s delays"
      sleep_with_interrupts "$UPDATE_FREQUENCY"
      continue
    fi
  fi
  
  BATCH_END=$MAX_AVAILABLE
  (( CURRENT_ID + MAX_BATCH_SIZE < BATCH_END )) && BATCH_END=$((CURRENT_ID + MAX_BATCH_SIZE))
  (( CURRENT_ID + MAX_BATCH_TIME / UPDATE_FREQUENCY < BATCH_END )) && BATCH_END=$((CURRENT_ID + MAX_BATCH_TIME / UPDATE_FREQUENCY))
  
  BATCH_COUNT=$((BATCH_END - CURRENT_ID))
  if [[ $BATCH_COUNT -eq 1 ]]; then
    log_message "Fetching $BATCH_END"
  else
    log_message "Fetching $BATCH_COUNT files ($((CURRENT_ID + 1)) to $BATCH_END)"
  fi
  
  if download_batch "$CURRENT_ID" "$BATCH_END"; then
    LAST_UPDATE_TIME=$(date +%s)
    update_fetch_state "$BATCH_END"
    CURRENT_ID=$BATCH_END
  else
    log_error "Batch download failed, retrying"
    sleep_with_interrupts "$UPDATE_FREQUENCY"
  fi
done
