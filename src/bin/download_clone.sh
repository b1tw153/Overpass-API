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

# Global variables
USAGE="Usage: $0 --db-dir=database_dir --source=https://dev.overpass-api.de/api_drolbr/ --meta=(yes|no|attic) [--parallel=N]"
EXEC_DIR="`pwd`/../"
CLONE_DIR=
REMOTE_DIR=
SOURCE=
META=
LOCK_FILE=
INTERRUPTED=0
PARALLEL_JOBS=3

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

# Process parameters
process_params()
{
  if [[ -z "$1" ]]; then
  {
    echo "$USAGE"
    exit 0
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
    };
    elif [[ "${arg:0:11}" == "--parallel=" ]]; then
    {
      PARALLEL_JOBS="${arg:11}"
    };
    else
    {
      echo "Unknown argument: $arg"
      exit 1
    }; fi
  }; done

  # Validate required parameters
  if [[ -z "$CLONE_DIR" ]]; then
  {
    echo "Error: --db-dir parameter is required"
    echo "$USAGE"
    exit 1
  }; fi

  if [[ -z "$SOURCE" ]]; then
  {
    echo "Error: --source parameter is required"
    echo "$USAGE"
    exit 1
  }; fi

  # Initialize lock file path
  LOCK_FILE="$CLONE_DIR/.download_clone.lock"
}

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

  # Only remove lock file if it contains our PID
  if [[ -f "$LOCK_FILE" ]]; then
  {
    local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ "$lock_pid" == "$$" ]]; then
    {
      rm -f "$LOCK_FILE"
    }; fi
  }; fi

  exit $exit_code
}

# Signal handler for graceful interruption
handle_interrupt()
{
  INTERRUPTED=1
  cleanup
}

# Get remote file info using HTTP HEAD request
# Returns: "size|last-modified" or empty string on error
get_remote_file_info()
{
  local url="$1"
  local headers

  # Use HEAD request to get file metadata without downloading
  headers=$(curl -s -I -L --max-time 30 "$url" 2>/dev/null)

  if [[ $? -ne 0 ]]; then
    echo "Warning: HEAD request failed for $url"
    return 1
  fi

  # Extract Content-Length and Last-Modified
  local size=$(echo "$headers" | grep -i "^Content-Length:" | tail -1 | awk '{print $2}' | tr -d '\r')
  local modified=$(echo "$headers" | grep -i "^Last-Modified:" | tail -1 | cut -d' ' -f2- | tr -d '\r')

  # Both headers must be present
  if [[ -n "$size" && -n "$modified" ]]; then
    echo "${size}|${modified}"
    return 0
  fi

  if [[ -z "$size" ]]; then
    echo "Warning: No Content-Length in response from $url"
  fi

  if [[ -z "$modified" ]]; then
    echo "Warning: No Last-Modified in response from $url"
  fi

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
    echo "Warning: Size mismatch for $local_file ($local_size <> $remote_size)"
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
      echo "Warning: Date mismatch for $local_file"
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

    # Move .tmp files to final destinations
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

# Main function
main()
{
  process_params "$@"

  mkdir -p "$CLONE_DIR"

  acquire_lock

  # Fetch the clone URL from the trigger_clone endpoint
  if ! curl -f -s -S -L --max-time 30 -o "$CLONE_DIR/base-url" "$SOURCE/trigger_clone"; then
  {
    echo "Error: Failed to retrieve clone URL from trigger endpoint"
    exit 1
  }; fi

  # Read and validate the clone URL
  REMOTE_DIR=$(cat "$CLONE_DIR/base-url")

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

  # Verify clone is accessible by fetching replicate_id
  if ! curl -f -s -S -L --max-time 30 -o "$CLONE_DIR/replicate_id" "$REMOTE_DIR/replicate_id"; then
  {
    echo "Error: Clone not accessible"
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

  echo "Database ready"
}

# Set up signal handlers
trap handle_interrupt SIGINT SIGTERM SIGHUP
trap cleanup EXIT

# Run main
main "$@"
