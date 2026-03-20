#!/usr/bin/env bash

# Copyright 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018 Roland Olbricht et al.
# With improvements in 2026 by Kai Johnson
#
# This file is part of Overpass_API.
#
# USAGE NOTE: This script downloads large database files and may take hours.
# For long-running downloads over SSH, use tmux or screen to prevent interruption:
#
#   tmux new -s download
#   ./download_clone.sh --db-dir=/data --source=https://...
#   # Detach: Ctrl+b, then d
#   # Reattach later: tmux attach -s download
#
# The script is resilient to interruptions and can resume if killed.
# Simply re-run with the same parameters to continue where it left off.
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

# Global variables
USAGE="Usage: $0 --db-dir=database_dir --source=https://dev.overpass-api.de/api_drolbr/ --meta=(yes|no|attic) [--parallel=N]"
CLONE_DIR=
REMOTE_DIR=
SOURCE=
META=
LOCK_FILE=
INTERRUPTED=0

# Download parameters
PARALLEL_JOBS=${DOWNLOAD_CLONE_PARALLEL_JOBS:-3}      # Number of parallel downloads
MAX_TIME=${DOWNLOAD_CLONE_MAX_TIME:-86400}            # 24 hours - total time limit for all downloads
CONNECT_TIMEOUT=${DOWNLOAD_CLONE_CONNECT_TIMEOUT:-30} # Timeout for initial connection
RETRY_COUNT=${DOWNLOAD_CLONE_RETRY_COUNT:-240}        # Number of retries per file
RETRY_DELAY=${DOWNLOAD_CLONE_RETRY_DELAY:-15}         # Seconds between retries
SPEED_LIMIT=${DOWNLOAD_CLONE_SPEED_LIMIT:-1024}       # Minimum bytes/sec before considering stalled
SPEED_TIME=${DOWNLOAD_CLONE_SPEED_TIME:-30}           # Seconds below speed limit before aborting

FILES_BASE="\
nodes.bin nodes.map node_tags_local.bin node_tags_global.bin node_frequent_tags.bin node_keys.bin \
ways.bin ways.map way_tags_local.bin way_tags_global.bin way_frequent_tags.bin way_keys.bin \
relations.bin relations.map relation_roles.bin relation_tags_local.bin relation_tags_global.bin relation_frequent_tags.bin relation_keys.bin"

FILES_META="\
nodes_meta.bin \
ways_meta.bin \
relations_meta.bin \
user_data.bin user_indices.bin"

FILES_ATTIC="\
nodes_attic.bin nodes_attic.map node_attic_indexes.bin nodes_attic_undeleted.bin nodes_meta_attic.bin \
node_changelog.bin node_tags_local_attic.bin node_tags_global_attic.bin node_frequent_tags_attic.bin \
ways_attic.bin ways_attic.map way_attic_indexes.bin ways_attic_undeleted.bin ways_meta_attic.bin \
way_changelog.bin way_tags_local_attic.bin way_tags_global_attic.bin way_frequent_tags_attic.bin \
relations_attic.bin relations_attic.map relation_attic_indexes.bin relations_attic_undeleted.bin relations_meta_attic.bin \
relation_changelog.bin relation_tags_local_attic.bin relation_tags_global_attic.bin relation_frequent_tags_attic.bin"

# Log error
log_error()
{
  local message="$1"
  echo "Error: $message" >&2
}

# Log warning
log_warning()
{
  local message="$1"
  echo "Warning: $message" >&2
}

# Log message
log_message()
{
  local message="$1"
  echo "$message"
}

# Process parameters
process_params()
{
  if [[ -z "$1" ]]; then
  {
    log_message "$USAGE"
    exit 1
  }; fi

  # Process all parameters
  for arg in "$@"; do
  {
    if [[ "${arg:0:9}" == "--db-dir=" ]]; then
    {
      CLONE_DIR="${arg:9}"
    };
    elif [[ "${arg:0:9}" == "--source=" ]]; then
    {
      SOURCE="${arg:9}"
    };
    elif [[ "${arg:0:7}" == "--meta=" ]]; then
    {
      META="${arg:7}"
      if ! [[ $META =~ ^(yes|no|attic)$ ]]; then
        log_error "Unknown value for --meta: $arg"
        exit 1
      fi
    };
    elif [[ "${arg:0:11}" == "--parallel=" ]]; then
    {
      PARALLEL_JOBS="${arg:11}"
    };
    else
    {
      log_error "Unknown argument: $arg"
      exit 1
    }; fi
  }; done

  # Validate required parameters
  if [[ -z "$CLONE_DIR" ]]; then
  {
    log_error "--db-dir parameter is required"
    log_message "$USAGE"
    exit 1
  }; fi

  if [[ -z "$SOURCE" ]]; then
  {
    log_error "--source parameter is required"
    log_message "$USAGE"
    exit 1
  }; fi

  # Initialize lock file path
  LOCK_FILE="$CLONE_DIR/.download_clone.lock"
}

# Verify global variables
verify_globals()
{
  if [[ ! $PARALLEL_JOBS =~ ^[1-9][0-9]*$ ]]; then
  {
    log_error "Invalid value for parallel jobs: $PARALLEL_JOBS"
    exit 1
  }; fi

  if [[ ! $MAX_TIME =~ ^[1-9][0-9]*$ ]]; then
  {
    log_error "Invalid value for max time: $MAX_TIME"
    exit 1
  }; fi

  if [[ ! $CONNECT_TIMEOUT =~ ^[1-9][0-9]*$ ]]; then
  {
    log_error "Invalid value for connect timeout: $CONNECT_TIMEOUT"
    exit 1
  }; fi

  if [[ ! $RETRY_COUNT =~ ^[0-9]+$ ]]; then
  {
    log_error "Invalid value for retry count: $RETRY_COUNT"
    exit 1
  }; fi

  if [[ ! $RETRY_DELAY =~ ^[0-9]+$ ]]; then
  {
    log_error "Invalid value for retry delay: $RETRY_DELAY"
    exit 1
  }; fi

  if [[ ! $SPEED_LIMIT =~ ^[0-9]+$ ]]; then
  {
    log_error "Invalid value for speed limit: $SPEED_LIMIT"
    exit 1
  }; fi

  if [[ ! $SPEED_TIME =~ ^[1-9][0-9]*$ ]]; then
  {
    log_error "Invalid value for speed time: $SPEED_TIME"
    exit 1
  }; fi
}

# Cleanup function - called on exit or interruption
# $1 - exit code (optional, defaults to $?)
cleanup()
{
  local exit_code=${1:-$?}

  if [[ $INTERRUPTED -eq 1 ]]; then
  {
    echo
    # Remove incomplete .tmp files
    find "$CLONE_DIR" -name "*.tmp" -type f -delete 2>/dev/null
  }; fi

  # Only remove lock file if it contains our PID
  if [[ -f "$LOCK_FILE" ]]; then
  {
    local lock_pid
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ "$lock_pid" == "$$" ]]; then
    {
      rm -f "$LOCK_FILE"
    }; fi
  }; fi

  exit $exit_code
}

# Signal handler for graceful interruption
# $1 - exit code (128 + signal number)
handle_interrupt()
{
  INTERRUPTED=1
  cleanup "$1"
}

# Get remote file size using HTTP HEAD request
# Returns: size in bytes, or empty string on error
get_remote_file_size()
{
  local url="$1"
  local headers
  local size

  # Use HEAD request to get file metadata without downloading
  headers=$(curl -s -I -L --max-time "$CONNECT_TIMEOUT" "$url" 2>/dev/null)

  if [[ $? -ne 0 ]]; then
    log_warning "HEAD request failed for $url"
    return 1
  fi

  # Extract Content-Length
  size=$(echo "$headers" | grep -i "^Content-Length:" | tail -1 | awk '{print $2}' | tr -d '\r')

  if [[ -n "$size" ]]; then
    echo "$size"
    return 0
  fi

  log_warning "No Content-Length in response from $url"
  return 1
}

# Check if local file matches remote file by size
# Returns 0 if file is complete, 1 otherwise
is_file_complete()
{
  local url="$1"
  local local_file="$2"
  local remote_size
  local local_size

  # If local file doesn't exist or is empty, it's not complete
  if [[ ! -s "$local_file" ]]; then
    return 1
  fi

  # Get remote file size
  remote_size=$(get_remote_file_size "$url")
  if [[ -z "$remote_size" ]]; then
    # Can't get remote size, assume file needs download
    return 1
  fi

  local_size=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file" 2>/dev/null)

  # Sizes must match
  if [[ "$local_size" -ne "$remote_size" ]]; then
    return 1
  fi

  return 0
}

# Check and create lock file to prevent concurrent runs
acquire_lock()
{
  if [[ -f "$LOCK_FILE" ]]; then
  {
    local lock_pid
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    {
      log_error "Another instance of this script is already running (PID: $lock_pid)\nIf this is incorrect, remove the lock file: $LOCK_FILE"
      exit 1
    }
    else
    {
      log_message "Removing stale lock file from PID $lock_pid"
      rm -f "$LOCK_FILE"
    }; fi
  }; fi

  # Create lock file with current PID
  if ! echo $$ > "$LOCK_FILE"; then
  {
    log_error "Failed to create lock file: $LOCK_FILE"
    exit 1
  }; fi
}

# Download multiple files in parallel using curl's built-in parallel support
# Takes a space-separated list of filenames
download_files_parallel()
{
  local files="$1"
  local curl_args
  local CURL_ERROR_LOG="$CLONE_DIR/curl_error_$$.log"

  # deadline is current time + MAX_TIME
  local DEADLINE=$(($(date '+%s') + MAX_TIME))

  # while current time is less than deadline
  while [[ $(date '+%s') -lt $DEADLINE ]]; do
  {
    curl_args=()

    # Build list of files that need downloading
    for file in $files; do
    {
      local data_file="$CLONE_DIR/$file"
      local idx_file="$CLONE_DIR/$file.idx"
      local data_url="$REMOTE_DIR/$file"
      local idx_url="$REMOTE_DIR/$file.idx"

      # Check data file
      if ! is_file_complete "$data_url" "$data_file"; then
      {
        log_message "Fetching $file"
        curl_args+=("$data_url" -o "$data_file.tmp")
      }; fi

      # Check index file
      if ! is_file_complete "$idx_url" "$idx_file"; then
      {
        log_message "Fetching $file.idx"
        curl_args+=("$idx_url" -o "$idx_file.tmp")
      }; fi
    }; done

    # Download all files in parallel if there are any to download
    if [[ ${#curl_args[@]} -gt 0 ]]; then
    {
      echo
      curl --parallel --parallel-immediate --parallel-max "$PARALLEL_JOBS" \
        -f -S -L \
        --retry "$RETRY_COUNT" \
        --retry-delay "$RETRY_DELAY" \
        --retry-max-time "$MAX_TIME" \
        --speed-limit "$SPEED_LIMIT" \
        --speed-time "$SPEED_TIME" \
        -C - \
        -R \
        --progress-bar \
        --http2 \
        "${curl_args[@]}" 2>"$CURL_ERROR_LOG"

      local CURL_EXIT=$?

      echo "curl command completed"

      if [[ $CURL_EXIT -ne 0 ]]; then
      {
        log_warning "Batch download failed (curl exit code: $CURL_EXIT)"

        # Log curl error details if available
        if [[ -s "$CURL_ERROR_LOG" ]]; then
          log_message "Curl error output:"
          while IFS= read -r line; do
            log_message "  $line"
          done < "$CURL_ERROR_LOG"
        fi

        # Determine if error is recoverable
        local recoverable=0

        case $CURL_EXIT in
          # Recoverable: transient network/server issues
          6)  log_message "Exit 6: Could not resolve host (will retry)"
              recoverable=1 ;;
          7)  log_message "Exit 7: Failed to connect to host (will retry)"
              recoverable=1 ;;
          16) log_message "Exit 16: HTTP/2 protocol error (will retry)"
              recoverable=1 ;;
          18) log_message "Exit 18: Partial file transfer (will retry)"
              recoverable=1 ;;
          28) log_message "Exit 28: Operation timeout (will retry)"
              recoverable=1 ;;
          35) log_message "Exit 35: SSL connect error (will retry)"
              recoverable=1 ;;
          52) log_message "Exit 52: Empty reply from server (will retry)"
              recoverable=1 ;;
          55) log_message "Exit 55: Failed sending network data (will retry)"
              recoverable=1 ;;
          56) log_message "Exit 56: Failed receiving network data (will retry)"
              recoverable=1 ;;

          # Non-recoverable: local filesystem issues
          23) log_error "Exit 23: Write error (non-recoverable)" ;;

          # HTTP errors: check the actual status codes
          22)
              log_message "Exit 22: HTTP error - checking status codes"
              # Extract HTTP status codes from curl error output
              # Format: "curl: (22) The requested URL returned error: 404"
              local http_codes
              http_codes=$(sed -nE 's/.*\(22\).*error: ([0-9]+).*/\1/p' "$CURL_ERROR_LOG" | sort -u)

              # Check for non-recoverable HTTP status codes
              local has_non_recoverable=0
              for code in $http_codes; do
                case $code in
                  # Recoverable HTTP errors
                  408|429|500|502|503|504)
                    log_message "  HTTP $code: recoverable (will retry)"
                    ;;
                  # Non-recoverable HTTP errors
                  400|401|403|404|405|410)
                    log_error "  HTTP $code: non-recoverable"
                    has_non_recoverable=1
                    ;;
                  # Unknown HTTP errors: treat as non-recoverable to be safe
                  *)
                    log_error "  HTTP $code: unknown (treating as non-recoverable)"
                    has_non_recoverable=1
                    ;;
                esac
              done

              if [[ $has_non_recoverable -eq 0 ]]; then
                recoverable=1
              fi
              ;;

          # Unknown curl exit codes: treat as non-recoverable
          *)  log_error "Exit $CURL_EXIT: unknown error (non-recoverable)" ;;
        esac

        # Non-recoverable: delete .tmp files and exit
        if [[ $recoverable -eq 0 ]]; then
          for file in $files; do
            rm -f "$CLONE_DIR/$file.tmp" "$CLONE_DIR/$file.idx.tmp"
          done
          rm -f "$CURL_ERROR_LOG"
          exit 1
        fi
      }; fi

      rm -f "$CURL_ERROR_LOG"

      # Move complete .tmp files to final destinations
      for file in $files; do
      {
        local data_tmp="$CLONE_DIR/$file.tmp"
        local idx_tmp="$CLONE_DIR/$file.idx.tmp"
        local data_url="$REMOTE_DIR/$file"
        local idx_url="$REMOTE_DIR/$file.idx"

        if [[ -f "$data_tmp" ]] && is_file_complete "$data_url" "$data_tmp"; then
          mv "$data_tmp" "$CLONE_DIR/$file" || exit 1
        fi

        if [[ -f "$idx_tmp" ]] && is_file_complete "$idx_url" "$idx_tmp"; then
          mv "$idx_tmp" "$CLONE_DIR/$file.idx" || exit 1
        fi
      }; done

      # Recoverable error: sleep and retry
      if [[ $CURL_EXIT -ne 0 ]]; then
        log_message "Retrying in $RETRY_DELAY seconds..."
        sleep "$RETRY_DELAY"
      fi
    }
    else
    {
      # All files are complete
      return 0
    }; fi
  }; done

  # If we reach here, time limit was reached
  log_error "Time limit reached without completing all downloads"
  exit 1
}

# Main function
main()
{
  process_params "$@"

  verify_globals

  if ! mkdir -p "$CLONE_DIR"; then
  {
    log_error "Failed to create or access database directory: $CLONE_DIR"
    exit 1
  }; fi

  acquire_lock

  # Fetch the clone URL from the trigger_clone endpoint
  if ! curl -f -s -S -L --max-time "$CONNECT_TIMEOUT" -o "$CLONE_DIR/base-url" "$SOURCE/trigger_clone"; then
  {
    log_error "Failed to retrieve clone URL from trigger endpoint"
    exit 1
  }; fi

  # Read and validate the clone URL
  REMOTE_DIR=$(cat "$CLONE_DIR/base-url")

  if [[ -z "$REMOTE_DIR" ]]; then
  {
    log_error "Empty URL from trigger_clone"
    exit 1
  }; fi

  if [[ ! "$REMOTE_DIR" =~ ^https?://[^[:space:]]+$ ]]; then
  {
    log_error "Invalid URL from trigger_clone"
    exit 1
  }; fi

  # Verify clone is accessible by fetching replicate_id
  if ! curl -f -s -S -L --max-time "$CONNECT_TIMEOUT" -o "$CLONE_DIR/replicate_id" "$REMOTE_DIR/replicate_id"; then
  {
    log_error "Clone not accessible"
    exit 1
  }; fi

  # Download files
  download_files_parallel "$FILES_BASE"

  if [[ $META == "yes" || $META == "attic" ]]; then
  {
    download_files_parallel "$FILES_META"
  }; fi

  if [[ $META == "attic" ]]; then
  {
    download_files_parallel "$FILES_ATTIC"
  }; fi

  log_message "Database ready"
}

# Set up signal handlers (exit code = 128 + signal number)
trap 'handle_interrupt 143' SIGTERM
trap 'handle_interrupt 130' SIGINT
trap 'handle_interrupt 129' SIGHUP
trap cleanup EXIT

# Run main
main "$@"
