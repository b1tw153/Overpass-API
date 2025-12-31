#!/usr/bin/env bash

# Copyright 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018 Roland Olbricht et al.
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

EXEC_DIR="`pwd`/../"
CLONE_DIR="$1"
REMOTE_DIR=
SOURCE=
DONE=
META=
LOCK_FILE=
INTERRUPTED=0
PARALLEL_JOBS=3

if [[ -z $1 ]]; then
{
  echo "Usage: $0 --db-dir=database_dir --source=https://dev.overpass-api.de/api_drolbr/ --meta=(yes|no|attic) [--parallel=N]"
  exit 0
}; fi

process_param()
{
  if [[ "${1:0:9}" == "--db-dir=" ]]; then
  {
    CLONE_DIR="${1:9}"
  };
  elif [[ "${1:0:9}" == "--source=" ]]; then
  {
    SOURCE="${1:9}"
  };
  elif [[ "${1:0:7}" == "--meta=" ]]; then
  {
    META="${1:7}"
  };
  elif [[ "${1:0:11}" == "--parallel=" ]]; then
  {
    PARALLEL_JOBS="${1:11}"
  };
  else
  {
    echo "Unknown argument: $1"
    exit 0
  };
  fi
};

if [[ -n $1  ]]; then process_param $1; fi
if [[ -n $2  ]]; then process_param $2; fi
if [[ -n $3  ]]; then process_param $3; fi
if [[ -n $4  ]]; then process_param $4; fi

# Validate required parameters
if [[ -z "$CLONE_DIR" ]]; then
{
  echo "Error: --db-dir parameter is required"
  echo "Usage: $0 --db-dir=database_dir --source=https://dev.overpass-api.de/api_drolbr/ --meta=(yes|no|attic) [--parallel=N]"
  exit 1
}; fi

if [[ -z "$SOURCE" ]]; then
{
  echo "Error: --source parameter is required"
  echo "Usage: $0 --db-dir=database_dir --source=https://dev.overpass-api.de/api_drolbr/ --meta=(yes|no|attic) [--parallel=N]"
  exit 1
}; fi

# Initialize lock file
LOCK_FILE="$CLONE_DIR/.download_clone.lock"

# Cleanup function - called on exit or interruption
cleanup()
{
  local exit_code=$?

  if [[ $INTERRUPTED -eq 1 ]]; then
  {
    echo
    # Remove incomplete .tmp files
    find "$CLONE_DIR" -name "*.tmp" -type f -delete 2>/dev/null
  }; fi

  # Always remove lock file
  if [[ -f "$LOCK_FILE" ]]; then
  {
    rm -f "$LOCK_FILE"
  }; fi

  exit $exit_code
}

# Signal handler for graceful interruption
handle_interrupt()
{
  INTERRUPTED=1
  cleanup
}

# Set up signal handlers
trap handle_interrupt SIGINT SIGTERM SIGHUP

# Set cleanup to run on exit
trap cleanup EXIT

# Get remote file info using HTTP HEAD request
# Returns: "size|last-modified" or empty string on error
get_remote_file_info()
{
  local url="$1"
  local headers

  # Use HEAD request to get file metadata without downloading
  headers=$(curl -s -I -L --max-time 30 "$url" 2>/dev/null)

  if [[ $? -ne 0 ]]; then
    echo "Warning: HEAD request failed for $url" >&2
    return 1
  fi

  # Extract Content-Length and Last-Modified
  local size=$(echo "$headers" | grep -i "^Content-Length:" | tail -1 | awk '{print $2}' | tr -d '\r')
  local modified=$(echo "$headers" | grep -i "^Last-Modified:" | tail -1 | cut -d' ' -f2- | tr -d '\r')

  if [[ -n "$size" ]]; then
    echo "${size}|${modified}"
    return 0
  fi

  echo "Warning: No Content-Length in response from $url" >&2
  return 1
}

# Check if local file matches remote file (by size and modification time)
# Returns 0 if file is complete and matches, 1 otherwise
is_file_complete()
{
  local url="$1"
  local local_file="$2"

  # If local file doesn't exist, it's not complete
  if [[ ! -f "$local_file" ]]; then
    return 1
  fi

  # Get remote file info
  local remote_info=$(get_remote_file_info "$url")
  if [[ -z "$remote_info" ]]; then
    # Can't get remote info, assume file needs download
    return 1
  fi

  local remote_size=$(echo "$remote_info" | cut -d'|' -f1)
  local remote_modified=$(echo "$remote_info" | cut -d'|' -f2)
  local local_size=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file" 2>/dev/null)

  # First check: sizes must match
  if [[ "$local_size" -ne "$remote_size" ]]; then
    return 1
  fi

  # Second check: modification times should match (if available)
  if [[ -n "$remote_modified" ]]; then
  {
    # Convert remote Last-Modified to epoch for comparison
    local remote_epoch=$(date -d "$remote_modified" +%s 2>/dev/null || date -j -f "%a, %d %b %Y %H:%M:%S %Z" "$remote_modified" +%s 2>/dev/null)
    local local_epoch=$(stat -f%m "$local_file" 2>/dev/null || stat -c%Y "$local_file" 2>/dev/null)

    if [[ -n "$remote_epoch" && "$local_epoch" -ne "$remote_epoch" ]]; then
    {
      echo "Warning: Date mismatch for $local_file" >&2
      return 1
    }; fi
  }; fi

  # Both size and date match - file is complete and correct
  return 0
}

# Check and create lock file to prevent concurrent runs
acquire_lock()
{
  if [[ -f "$LOCK_FILE" ]]; then
  {
    local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    {
      echo "Error: Another instance of this script is already running (PID: $lock_pid)"
      echo "If this is incorrect, remove the lock file: $LOCK_FILE"
      exit 1
    }
    else
    {
      echo "Removing stale lock file from PID $lock_pid"
      rm -f "$LOCK_FILE"
    }; fi
  }; fi

  # Create lock file with current PID
  echo $$ > "$LOCK_FILE"
}

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

# Improved fetch function using curl with automatic retries and atomic operations
# $1 - remote source URL
# $2 - local destination path
# $3 - optional: max retry time in seconds (default: 86400 = 24 hours)
# $4 - optional: skip atomic operation (for small metadata files)
fetch_file()
{
  local url="$1"
  local dest="$2"
  local max_time="${3:-86400}"
  local skip_atomic="${4:-0}"
  local temp_dest="$dest"

  # Use atomic operation for large files: download to .tmp, then rename
  if [[ $skip_atomic -eq 0 ]]; then
  {
    temp_dest="$dest.tmp"
  }; fi

  # curl options:
  # -f, --fail: Fail on HTTP errors (4xx, 5xx)
  # -S, --show-error: Show errors even when silent
  # -L, --location: Follow redirects
  # --retry: Number of retries on transient errors
  # --retry-delay: Wait time between retries
  # --retry-max-time: Maximum time to spend retrying
  # --retry-all-errors: Retry on all errors, not just transient ones
  # -C -: Continue/resume partial downloads
  # -R, --remote-time: Set local file's timestamp to match remote Last-Modified
  # -o: Output file
  # --progress-bar: Show simple progress bar instead of detailed stats
  # --http2: Use HTTP/2 if available (better connection reuse and performance)
  curl -f -S -L \
    --retry 240 \
    --retry-delay 15 \
    --retry-max-time "$max_time" \
    --retry-all-errors \
    -C - \
    -R \
    --progress-bar \
    --http2 \
    -o "$temp_dest" \
    "$url"

  local exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
  {
    echo "Error: Failed to download $url (exit code: $exit_code)"
    return $exit_code
  }; fi

  # Verify the file was actually downloaded and has content
  if [[ ! -s "$temp_dest" ]]; then
  {
    echo "Error: Downloaded file $temp_dest is empty or missing"
    return 1
  }; fi

  # Atomically move temp file to final destination
  if [[ $skip_atomic -eq 0 ]]; then
  {
    mv "$temp_dest" "$dest"
    if [[ $? -ne 0 ]]; then
    {
      echo "Error: Failed to move $temp_dest to $dest"
      return 1
    }; fi
  }; fi

  return 0
}

# Download multiple files in parallel using curl's built-in parallel support
# Takes a space-separated list of filenames
download_files_parallel()
{
  local files="$1"
  local curl_args=()

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
      echo "Fetching $file"
      curl_args+=("$data_url" -o "$data_file.tmp")
    }; fi

    # Check index file
    if ! is_file_complete "$idx_url" "$idx_file"; then
    {
      echo "Fetching $file.idx"
      curl_args+=("$idx_url" -o "$idx_file.tmp")
    }; fi
  }; done

  # Download all files in parallel if there are any to download
  if [[ ${#curl_args[@]} -gt 0 ]]; then
  {
    echo
    curl --parallel --parallel-max "$PARALLEL_JOBS" \
      -f -S -L \
      --retry 240 \
      --retry-delay 15 \
      --retry-max-time 86400 \
      --retry-all-errors \
      -C - \
      -R \
      --progress-bar \
      --http2 \
      "${curl_args[@]}"

    if [[ $? -ne 0 ]]; then
    {
      echo "Error: Parallel download failed"
      exit 1
    }; fi

    # Atomically move .tmp files to final destinations
    for file in $files; do
    {
      local data_tmp="$CLONE_DIR/$file.tmp"
      local idx_tmp="$CLONE_DIR/$file.idx.tmp"

      if [[ -f "$data_tmp" ]]; then
      {
        mv "$data_tmp" "$CLONE_DIR/$file" || exit 1
      }; fi

      if [[ -f "$idx_tmp" ]]; then
      {
        mv "$idx_tmp" "$CLONE_DIR/$file.idx" || exit 1
      }; fi
    }; done
  }; fi
}

mkdir -p "$CLONE_DIR"

# Acquire lock to prevent concurrent runs
acquire_lock

# Fetch the clone URL from the trigger_clone endpoint
if ! fetch_file "$SOURCE/trigger_clone" "$CLONE_DIR/base-url" 300 1; then
{
  echo "Error: Failed to retrieve clone URL from trigger endpoint"
  exit 1
}; fi

# Read and validate the clone URL
REMOTE_DIR=$(cat <"$CLONE_DIR/base-url")

if [[ -z "$REMOTE_DIR" ]]; then
{
  echo "Error: Empty URL from trigger_clone"
  exit 1
}; fi

if [[ ! "$REMOTE_DIR" =~ ^https?://[^[:space:]]+$ ]]; then
{
  echo "Error: Invalid URL from trigger_clone"
  exit 1
}; fi

if ! fetch_file "$REMOTE_DIR/replicate_id" "$CLONE_DIR/replicate_id" 300 1; then
{
  echo "Error: Clone not accessible"
  exit 1
}; fi

download_files_parallel "$FILES_BASE"

if [[ $META == "yes" || $META == "attic" ]]; then
{
  download_files_parallel "$FILES_META"
}; fi

if [[ $META == "attic" ]]; then
{
  download_files_parallel "$FILES_ATTIC"
}; fi

echo " database ready."
