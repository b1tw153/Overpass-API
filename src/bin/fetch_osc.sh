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
  cat << EOF
Usage: $0 replicate_id diff_url diff_dir [sleep]

  replicate_id   Starting replicate ID or 'auto' to resume from last fetch
  diff_url       Remote replication source (e.g., https://planet.openstreetmap.org/replication/minute)
  diff_dir       Local directory for downloaded files
  sleep          (Optional, ignored - kept for compatibility)

Environment variables:
  OVERPASS_UPDATE_FREQUENCY        Update interval in seconds: 60, 3600, or 86400 (default: 60)
  OVERPASS_MIN_FREE_DISK_PERCENT   Minimum free disk space on the diff filesystem as a percentage;
                                   downloads halt if the threshold is not met (default: 5)
  FETCH_OSC_MAX_BATCH_SIZE         Maximum number of OSC files per batch download (default: 360)
  FETCH_OSC_MAX_BATCH_TIME         Maximum time span of a batch in seconds (default: 86400)
  FETCH_OSC_MAX_RETRIES            Maximum download attempts per file before giving up (default: 20)
  FETCH_OSC_RETRY_DELAY            Seconds between retry attempts (default: 15)
  FETCH_OSC_CONNECT_TIMEOUT        Connection timeout in seconds (default: 30)
  FETCH_OSC_KEEPALIVE_TIME         Seconds to keep idle connections alive (default: 20)
  FETCH_OSC_PARALLEL_MAX           Maximum parallel connections for batch downloads (default: 4)
  FETCH_OSC_PARALLEL_MODE          Batch download mode: "immediate" or "multiplexed"
                                   (default: multiplexed)
  FETCH_OSC_SPEED_LIMIT            Minimum download speed in bytes/sec; 0 to disable (default: 1024)
  FETCH_OSC_SPEED_TIME             Time in seconds over which to check minimum speed (default: 30)
EOF
  exit 1
fi

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

# Check for curl
if ! command -v curl > /dev/null 2>&1; then
  echo "ERROR: curl is not available"
  exit 1
fi

# Update timing configuration
UPDATE_FREQUENCY=${OVERPASS_UPDATE_FREQUENCY:-60}       # Frequency of updates in seconds (60, 3600, or 86400)
TRIM=$(( (UPDATE_FREQUENCY + 23) / 24 ))                # Start polling this many seconds before expected update
PHASE3_DELAY=1200                                        # Seconds between polls after backoff is exhausted

case $UPDATE_FREQUENCY in
  60)
    DELAYS=(0 0 0 0 0 0 2 2 3 5 8 11 17 26 38 58 86 130 195 291 438 657 985)
    ;;
  3600)
    DELAYS=(12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 18 27 41 61 91 137 205 308 461 692 1038)
    ;;
  86400)
    DELAYS=(288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 288 432 648 972)
    ;;
esac

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

# Disk space configuration
MIN_FREE_DISK_PERCENT=${OVERPASS_MIN_FREE_DISK_PERCENT:-5}

SOURCE_VERIFIED=false  # Flag to track if source URL has been verified

LAST_SCHEDULED=        # Last-Modified epoch of root state.txt when last new sequence was found
LATEST_AVAILABLE_ID=   # Result of get_latest_available_id
LATEST_ROOT_LM=        # Last-Modified epoch of root state.txt from last get_latest_available_id

# Get execution directory
EXEC_DIR="$(realpath "$(dirname "$0")")"

# Get database directory from dispatcher
DB_DIR=$("$EXEC_DIR/dispatcher" --show-dir)
DB_DIR="$(realpath "$DB_DIR")"

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
# VARIABLES
# ============================================================================
verify_globals()
{
  local MESSAGE
  if [[ ! "$UPDATE_FREQUENCY" =~ ^[1-9][0-9]+$ ]]; then
    MESSAGE="Invalid UPDATE_FREQUENCY: $UPDATE_FREQUENCY"
    log_error "$MESSAGE"
    exit 1
  fi

  if [[ UPDATE_FREQUENCY -ne 60 && UPDATE_FREQUENCY -ne 3600 && UPDATE_FREQUENCY -ne 86400 ]]; then
    MESSAGE="Invalid UPDATE_FREQUENCY: $UPDATE_FREQUENCY (must be 60, 3600, or 86400)"
    log_error "$MESSAGE"
    exit 1
  fi

  if [[ ! "$MAX_BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    MESSAGE="Invalid MAX_BATCH_SIZE: $MAX_BATCH_SIZE"
    log_error "$MESSAGE"
    exit 1
  fi

  local MAX_POSSIBLE_BATCH_TIME=$((MAX_BATCH_SIZE * UPDATE_FREQUENCY))
  if [[ $MAX_POSSIBLE_BATCH_TIME -gt 86400 ]]; then
    MESSAGE="WARNING: MAX_BATCH_SIZE ($MAX_BATCH_SIZE) with UPDATE_FREQUENCY ($UPDATE_FREQUENCY) exceeds one day"
    log_message "$MESSAGE"
  fi

  if [[ ! "$MAX_BATCH_TIME" =~ ^[1-9][0-9]+$ ]]; then
    MESSAGE="Invalid MAX_BATCH_TIME: $MAX_BATCH_TIME"
    log_error "$MESSAGE"
    exit 1
  fi

  # verify that MAX_BATCH_TIME is at least UPDATE_FREQUENCY
  if [[ $MAX_BATCH_TIME -lt $UPDATE_FREQUENCY ]]; then
    MESSAGE="MAX_BATCH_TIME ($MAX_BATCH_TIME) must be at least UPDATE_FREQUENCY ($UPDATE_FREQUENCY)"
    log_error "$MESSAGE"
    exit 1
  fi

  # verify that MAX_BATCH_TIME is less than one day
  if [[ $MAX_BATCH_TIME -gt 86400 ]]; then
    MESSAGE="WARNING: MAX_BATCH_TIME ($MAX_BATCH_TIME) exceeds one day"
    log_message "$MESSAGE"
  fi

  if [[ ! "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
    MESSAGE="Invalid MAX_RETRIES: $MAX_RETRIES"
    log_error "$MESSAGE"
    exit 1
  fi

  if [[ ! "$RETRY_DELAY" =~ ^[1-9][0-9]*$ ]]; then
    MESSAGE="Invalid RETRY_DELAY: $RETRY_DELAY"
    log_error "$MESSAGE"
    exit 1
  fi

  if [[ ! "$CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    MESSAGE="Invalid CONNECT_TIMEOUT: $CONNECT_TIMEOUT"
    log_error "$MESSAGE"
    exit 1
  fi

  if [[ ! "$KEEPALIVE_TIME" =~ ^[1-9][0-9]*$ ]]; then
    MESSAGE="Invalid KEEPALIVE_TIME: $KEEPALIVE_TIME"
    log_error "$MESSAGE"
    exit 1
  fi

  if [[ ! "$PARALLEL_MAX" =~ ^[1-9][0-9]*$ ]]; then
    MESSAGE="Invalid PARALLEL_MAX: $PARALLEL_MAX"
    log_error "$MESSAGE"
    exit 1
  fi

  if [[ ! "$PARALLEL_MODE" =~ ^(immediate|multiplexed)$ ]]; then
    MESSAGE="Invalid PARALLEL_MODE: $PARALLEL_MODE (must be \"immediate\" or \"multiplexed\")"
    log_error "$MESSAGE"
    exit 1
  fi

  if [[ ! "$SPEED_LIMIT" =~ ^[0-9]+$ ]]; then
    MESSAGE="Invalid SPEED_LIMIT: $SPEED_LIMIT"
    log_error "$MESSAGE"
    exit 1
  fi

  if [[ ! "$SPEED_TIME" =~ ^[1-9][0-9]*$ ]]; then
    MESSAGE="Invalid SPEED_TIME: $SPEED_TIME"
    log_error "$MESSAGE"
    exit 1
  fi

  if [[ ! "$MIN_FREE_DISK_PERCENT" =~ ^[0-9]+$ || $MIN_FREE_DISK_PERCENT -ge 100 ]]; then
    MESSAGE="Invalid OVERPASS_MIN_FREE_DISK_PERCENT: $MIN_FREE_DISK_PERCENT (must be an integer from 0 to 99)"
    log_error "$MESSAGE"
    exit 1
  fi

}

# ============================================================================
# TIMING
# ============================================================================

sleep_until_check_time()
{
  local NOW T_START SLEEP_TIME
  NOW=$(date +%s)
  T_START=$(( LAST_SCHEDULED + UPDATE_FREQUENCY - TRIM ))
  SLEEP_TIME=$(( T_START - NOW ))

  if [[ $SLEEP_TIME -gt 0 ]]; then
    log_message "Sleeping until next file should be available ($(date -d @$T_START -u '+%F %T'))"
    sleep_with_interrupts "$SLEEP_TIME"
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
  LATEST_AVAILABLE_ID=
  LATEST_ROOT_LM=
  local REMOTE_STATE="$LOCAL_DIR/state.txt"
  local REMOTE_STATE_TMP="$REMOTE_STATE.tmp"
  local REMOTE_HEADERS_TMP="$REMOTE_STATE.hdr.tmp"

  while true; do
    rm -f "$REMOTE_STATE_TMP" "$REMOTE_HEADERS_TMP"

    curl -fsSL \
      --keepalive-time "$KEEPALIVE_TIME" \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --retry 3 \
      --retry-delay 5 \
      --retry-all-errors \
      -D "$REMOTE_HEADERS_TMP" \
      -o "$REMOTE_STATE_TMP" \
      "$SOURCE_URL/state.txt" \
      2>/dev/null

    local TOOL_EXIT=$?

    if [[ $TOOL_EXIT -eq 0 && -s "$REMOTE_STATE_TMP" ]]; then
      if verify_file "$REMOTE_STATE_TMP" "text"; then
        local SEQ_LINE LM_LINE LM_EPOCH
        SEQ_LINE=$(grep -E '^sequenceNumber=[1-9][0-9]*$' "$REMOTE_STATE_TMP")
        if [[ -n "$SEQ_LINE" ]]; then
          LM_LINE=$(grep -i '^last-modified:' "$REMOTE_HEADERS_TMP" | tail -1 | tr -d '\r' | sed 's/^[^:]*: //')
          LM_EPOCH=$(date -d "$LM_LINE" +%s 2>/dev/null)
          rm -f "$REMOTE_HEADERS_TMP"
          if [[ -z "$LM_EPOCH" ]]; then
            log_error "Last-Modified header missing or malformed in HTTP response for state.txt"
            rm -f "$REMOTE_STATE_TMP"
          else
            mv "$REMOTE_STATE_TMP" "$REMOTE_STATE" || log_error "Unable to update $REMOTE_STATE"
            LATEST_AVAILABLE_ID=$((${SEQ_LINE#*=} + 0))
            LATEST_ROOT_LM=$LM_EPOCH
            return 0
          fi
        fi
      else
        log_error "Downloaded state.txt failed validation (may be HTML error page or corrupted data)"
        rm -f "$REMOTE_STATE_TMP" "$REMOTE_HEADERS_TMP"
      fi
    fi

    # Download failed or file invalid
    if [[ "$SOURCE_VERIFIED" == "true" ]]; then
      # Source was previously working - wait patiently and retry
      log_message "Unable to reach replication source (likely network outage), sleeping ${UPDATE_FREQUENCY}s..."
      sleep_with_interrupts "$UPDATE_FREQUENCY"
      log_message "Retrying to reach replication source"
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

  curl -fSL \
    --no-progress-meter \
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

  download_batch_with_curl

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
# DISK SPACE CHECK
# ============================================================================

check_diff_disk_space()
{
  local USED_PCT FREE_PCT
  USED_PCT=$(df --output=pcent "$LOCAL_DIR" | tail -1 | tr -d ' %')
  FREE_PCT=$(( 100 - USED_PCT ))
  if [[ $FREE_PCT -lt $MIN_FREE_DISK_PERCENT ]]; then
    log_error "Insufficient free disk space on diff filesystem: ${FREE_PCT}% free (minimum: ${MIN_FREE_DISK_PERCENT}%)"
    exit 1
  fi
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
    find "$LOCAL_DIR" -name "curl_error_*.log" -type f -delete
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

log_message "-----------------------------------"
log_message "Starting Fetch Process ($0)"
log_message "-----------------------------------"
log_message "OVERPASS_REPLICATE_ID              $START_ID"
log_message "OVERPASS_DIFF_URL                  $SOURCE_URL"
log_message "OVERPASS_DIFF_DIR                  $LOCAL_DIR"
log_message "OVERPASS_UPDATE_FREQUENCY          $UPDATE_FREQUENCY"
log_message "OVERPASS_MIN_FREE_DISK_PERCENT     $MIN_FREE_DISK_PERCENT"
log_message "FETCH_OSC_MAX_BATCH_SIZE           $MAX_BATCH_SIZE"
log_message "FETCH_OSC_MAX_BATCH_TIME           $MAX_BATCH_TIME"
log_message "FETCH_OSC_MAX_RETRIES              $MAX_RETRIES"
log_message "FETCH_OSC_RETRY_DELAY              $RETRY_DELAY"
log_message "FETCH_OSC_CONNECT_TIMEOUT          $CONNECT_TIMEOUT"
log_message "FETCH_OSC_KEEPALIVE_TIME           $KEEPALIVE_TIME"
log_message "FETCH_OSC_PARALLEL_MAX             $PARALLEL_MAX"
log_message "FETCH_OSC_PARALLEL_MODE            $PARALLEL_MODE"
log_message "FETCH_OSC_SPEED_LIMIT              $SPEED_LIMIT"
log_message "FETCH_OSC_SPEED_TIME               $SPEED_TIME"
log_message "-----------------------------------"

if [[ "$START_ID" == "auto" ]]; then
  if [[ ! -f "$DB_STATE_FILE" || ! -s "$DB_STATE_FILE" ]]; then
    log_error "$DB_STATE_FILE does not exist and start set to auto"
    log_error "Auto mode requires an existing replicate_id to resume from"
    log_error "Use an explicit replicate ID instead of 'auto'"
    exit 1
  fi

  CURRENT_ID=$(read_db_state)
  log_message "Auto mode: resuming from $CURRENT_ID (database state)"
else
  # In explicit mode, START_ID is the first file to download
  # Set CURRENT_ID to the file before it (last file we "already have")
  CURRENT_ID=$((START_ID - 1))
  log_message "Starting from $START_ID"
fi

while true; do
  check_diff_disk_space

  if ! get_latest_available_id; then
    log_error "Cannot initialize - replication source unreachable or invalid"
    exit 1
  fi
  MAX_AVAILABLE=$LATEST_AVAILABLE_ID
  LAST_SCHEDULED=$LATEST_ROOT_LM
  
  # Mark source as verified after first successful fetch
  if [[ "$SOURCE_VERIFIED" != "true" ]]; then
    SOURCE_VERIFIED=true
    log_message "Replication source verified and operational"
  fi
  
  if [[ $MAX_AVAILABLE -le $CURRENT_ID ]]; then
    sleep_until_check_time

    DELAY_INDEX=0
    while [[ $MAX_AVAILABLE -le $CURRENT_ID ]]; do
      get_latest_available_id
      MAX_AVAILABLE=$LATEST_AVAILABLE_ID

      if [[ $MAX_AVAILABLE -gt $CURRENT_ID ]]; then
        break
      fi

      if [[ $DELAY_INDEX -lt ${#DELAYS[@]} ]]; then
        DELAY=${DELAYS[$DELAY_INDEX]}
        (( ++DELAY_INDEX ))
        log_message "Waiting for file $((CURRENT_ID + 1)) (${DELAY}s)"
        [[ $DELAY -gt 0 ]] && sleep_with_interrupts "$DELAY"
      else
        log_message "Waiting for file $((CURRENT_ID + 1)) (${PHASE3_DELAY}s)"
        sleep_with_interrupts "$PHASE3_DELAY"
      fi
    done
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
    update_fetch_state "$BATCH_END"
    CURRENT_ID=$BATCH_END
  else
    log_error "Batch download failed, retrying"
    sleep_with_interrupts "$UPDATE_FREQUENCY"
  fi
done
