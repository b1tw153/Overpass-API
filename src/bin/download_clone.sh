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

if [[ -z $1 ]]; then
{
  echo "Usage: $0 --db-dir=database_dir --source=https://dev.overpass-api.de/api_drolbr/ --meta=(yes|no|attic)"
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

# Validate required parameters
if [[ -z "$CLONE_DIR" ]]; then
{
  echo "Error: --db-dir parameter is required"
  echo "Usage: $0 --db-dir=database_dir --source=https://dev.overpass-api.de/api_drolbr/ --meta=(yes|no|attic)"
  exit 1
}; fi

if [[ -z "$SOURCE" ]]; then
{
  echo "Error: --source parameter is required"
  echo "Usage: $0 --db-dir=database_dir --source=https://dev.overpass-api.de/api_drolbr/ --meta=(yes|no|attic)"
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
    echo "============================================"
    echo "Download interrupted! Cleaning up..."
    echo "============================================"

    # Remove incomplete .tmp files
    find "$CLONE_DIR" -name "*.tmp" -type f -delete 2>/dev/null

    echo "Partial downloads saved. Re-run the script to continue."
    echo "Files are verified by size against the remote server."
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
  echo
  echo "Received interrupt signal. Stopping downloads gracefully..."
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
    return 1
  fi

  # Extract Content-Length and Last-Modified
  local size=$(echo "$headers" | grep -i "^Content-Length:" | tail -1 | awk '{print $2}' | tr -d '\r')
  local modified=$(echo "$headers" | grep -i "^Last-Modified:" | tail -1 | cut -d' ' -f2- | tr -d '\r')

  if [[ -n "$size" ]]; then
    echo "${size}|${modified}"
    return 0
  fi

  return 1
}

# Check if local file matches remote file (by size and optionally mtime)
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

  # Compare sizes
  if [[ "$local_size" -eq "$remote_size" ]]; then
    # Sizes match - file is complete
    # Optionally update mtime to match remote
    if [[ -n "$remote_modified" ]]; then
      touch -d "$remote_modified" "$local_file" 2>/dev/null || true
    fi
    return 0
  fi

  return 1
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
  # -o: Output file
  # --progress-bar: Show simple progress bar instead of detailed stats
  # --http2: Use HTTP/2 if available (better connection reuse and performance)
  curl -f -S -L \
    --retry 240 \
    --retry-delay 15 \
    --retry-max-time "$max_time" \
    --retry-all-errors \
    -C - \
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

download_file()
{
  local filename="$1"
  local data_file="$CLONE_DIR/$filename"
  local idx_file="$CLONE_DIR/$filename.idx"

  echo

  # Check if data file is already complete (via HEAD request)
  if is_file_complete "$REMOTE_DIR/$filename" "$data_file"; then
  {
    echo "✓ Skipping $filename (already complete, size matches remote)"
  }
  else
  {
    echo "Fetching $filename"
    if ! fetch_file "$REMOTE_DIR/$filename" "$data_file"; then
    {
      echo "Failed to download $filename. Aborting."
      exit 1
    }; fi
  }; fi

  # Check if index file is already complete (via HEAD request)
  if is_file_complete "$REMOTE_DIR/$filename.idx" "$idx_file"; then
  {
    echo "✓ Skipping $filename.idx (already complete, size matches remote)"
  }
  else
  {
    echo "Fetching $filename.idx"
    if ! fetch_file "$REMOTE_DIR/$filename.idx" "$idx_file"; then
    {
      echo "Failed to download $filename.idx. Aborting."
      exit 1
    }; fi
  }; fi
}

mkdir -p "$CLONE_DIR"

# Acquire lock to prevent concurrent runs
acquire_lock

# Check if this is a resume (any .bin files already exist)
if ls "$CLONE_DIR"/*.bin >/dev/null 2>&1; then
{
  echo "============================================"
  echo "Resuming download"
  echo "============================================"
  echo "Existing files found. Verifying against remote server..."
  echo "Complete files (matching remote size) will be skipped."
  echo
}; fi

# Fetch the clone URL from the trigger_clone endpoint
echo "Requesting clone URL from $SOURCE/trigger_clone"
if ! fetch_file "$SOURCE/trigger_clone" "$CLONE_DIR/base-url" 300 1; then
{
  echo "Error: Failed to retrieve clone URL from trigger endpoint"
  echo "Please verify that $SOURCE is accessible and correct"
  exit 1
}; fi

# Read and validate the clone URL
REMOTE_DIR=$(cat <"$CLONE_DIR/base-url")

# Validate that we received a valid HTTP/HTTPS URL
if [[ -z "$REMOTE_DIR" ]]; then
{
  echo "Error: Received empty URL from trigger_clone endpoint"
  echo "Expected a valid clone URL but got nothing"
  exit 1
}; fi

if [[ ! "$REMOTE_DIR" =~ ^https?://[^[:space:]]+$ ]]; then
{
  echo "Error: Invalid URL received from trigger_clone endpoint"
  echo "Expected format: http://... or https://..."
  echo "Received: $REMOTE_DIR"
  exit 1
}; fi

echo "Clone URL: $REMOTE_DIR"

# Fetch the replicate_id to verify the clone URL is accessible
echo "Verifying clone availability..."
if ! fetch_file "$REMOTE_DIR/replicate_id" "$CLONE_DIR/replicate_id" 300 1; then
{
  echo "Error: Clone URL is not accessible or replicate_id is missing"
  echo "URL: $REMOTE_DIR/replicate_id"
  exit 1
}; fi

for I in $FILES_BASE; do
{
  download_file $I
}; done

if [[ $META == "yes" || $META == "attic" ]]; then
{
  for I in $FILES_META; do
  {
    download_file $I
  }; done
}; fi

if [[ $META == "attic" ]]; then
{
  for I in $FILES_ATTIC; do
  {
    download_file $I
  }; done
}; fi

echo
echo "============================================"
echo "Database clone completed successfully!"
echo "============================================"
echo "Clone source: $REMOTE_DIR"
echo "Destination: $CLONE_DIR"
echo "Replicate ID: $(cat "$CLONE_DIR/replicate_id" 2>/dev/null || echo "unknown")"
echo "Meta data: ${META:-no}"
echo "Database ready."
