#!/usr/bin/env bash

# Copyright 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018 Roland Olbricht et al.
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

EXEC_DIR="`pwd`/../"
CLONE_DIR="$1"
REMOTE_DIR=
SOURCE=
DONE=
META=

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

# Improved fetch function using curl with automatic retries
# $1 - remote source URL
# $2 - local destination path
# $3 - optional: max retry time in seconds (default: 86400 = 24 hours)
fetch_file()
{
  local url="$1"
  local dest="$2"
  local max_time="${3:-86400}"

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
    -o "$dest" \
    "$url"

  local exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
  {
    echo "Error: Failed to download $url (exit code: $exit_code)"
    return $exit_code
  }; fi

  # Verify the file was actually downloaded and has content
  if [[ ! -s "$dest" ]]; then
  {
    echo "Error: Downloaded file $dest is empty or missing"
    return 1
  }; fi

  return 0
}

download_file()
{
  echo
  echo "Fetching $1"
  if ! fetch_file "$REMOTE_DIR/$1" "$CLONE_DIR/$1"; then
  {
    echo "Failed to download $1. Aborting."
    exit 1
  }; fi

  echo "Fetching $1.idx"
  if ! fetch_file "$REMOTE_DIR/$1.idx" "$CLONE_DIR/$1.idx"; then
  {
    echo "Failed to download $1.idx. Aborting."
    exit 1
  }; fi
}

mkdir -p "$CLONE_DIR"

# Fetch the clone URL from the trigger_clone endpoint
echo "Requesting clone URL from $SOURCE/trigger_clone"
if ! fetch_file "$SOURCE/trigger_clone" "$CLONE_DIR/base-url" 300; then
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
if ! fetch_file "$REMOTE_DIR/replicate_id" "$CLONE_DIR/replicate_id"; then
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
