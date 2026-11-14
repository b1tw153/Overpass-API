#!/usr/bin/env bash

# Copyright 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018 Roland Olbricht et al.
# With improvements in 2026 by Kai Johnson
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
# Script: bisect_timestamp.sh
# Purpose: Finds the replication sequence number corresponding to a given
#          timestamp using binary search
# ============================================================================

usage() {
  cat >&2 << EOF
Usage: $0 [diff_url [diff_dir [target_time [lower [upper]]]]]

  diff_url     Replication source URL
               (e.g., https://planet.openstreetmap.org/replication/minute)
  diff_dir     Local directory for caching downloaded state files;
               uses the same directory and file structure as fetch_osc.sh
  target_time  Timestamp to search for (e.g., 2026-03-20T19\:46\:25Z)
  lower        Lower bound sequence number for binary search (default: 1)
  upper        Upper bound sequence number for binary search
               (default: current latest sequence number from diff_url)

Environment variables:
  OVERPASS_DIFF_URL       Same as diff_url argument
  OVERPASS_DIFF_DIR       Same as diff_dir argument
  OVERPASS_DB_VERSION     Same as target_time argument
                          (default: read from OVERPASS_DB_DIR/osm_base_version)
  BISECT_TIMESTAMP_LOWER  Lower bound (default: 1)
  BISECT_TIMESTAMP_UPPER  Same as upper argument
  OVERPASS_DB_DIR         Database directory (used when target_time
                          is not specified)

Outputs the sequence number of the last replication diff whose timestamp
is less than or equal to target_time. This is equivalent to the sequence
number of the last diff that would have been applied to the database.
EOF
}

warning() {
  echo "$(date -u '+%F %T'): WARNING: $1" >&2
}

error() {
  echo "$(date -u '+%F %T'): ERROR: $1" >&2
}

if (( $# == 0 )) && [[ -z "$OVERPASS_DIFF_URL" ]]; then
  usage
  exit 1
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

SOURCE_URL="${1:-$OVERPASS_DIFF_URL}"
LOCAL_DIR="${2:-$OVERPASS_DIFF_DIR}"
TARGET_TIME="${3:-$OVERPASS_DB_VERSION}"
LOWER="${4:-${BISECT_TIMESTAMP_LOWER:-1}}"
UPPER="${5:-${BISECT_TIMESTAMP_UPPER:-}}"

# Validate source_url
if [[ -z "$SOURCE_URL" ]]; then
  error "source_url is required (or set OVERPASS_DIFF_URL)"
  usage
  exit 1
fi

if [[ ! "$SOURCE_URL" =~ ^https?:// ]]; then
  error "Invalid source_url '$SOURCE_URL': must start with http:// or https://"
  usage
  exit 1
fi

SOURCE_URL="${SOURCE_URL%/}"

# Validate local_dir
if [[ -z "$LOCAL_DIR" ]]; then
  error "local_dir is required (or set OVERPASS_DIFF_DIR)"
  usage
  exit 1
fi

if ! mkdir -p "$LOCAL_DIR" 2>/dev/null; then
  error "local_dir '$LOCAL_DIR' is not writable or cannot be created"
  exit 1
fi

LOCAL_DIR="$(realpath "$LOCAL_DIR")"

# Validate/default target_time
if [[ -z "$TARGET_TIME" ]]; then
  EXEC_DIR="$(dirname "$(realpath "$0")")"

  if [[ -n "$OVERPASS_DB_DIR" ]]; then
    OVERPASS_DB_DIR="$(realpath "$OVERPASS_DB_DIR")"
    if [[ -s "$OVERPASS_DB_DIR/osm_base_version" ]]; then
      TARGET_TIME=$(cat "$OVERPASS_DB_DIR/osm_base_version")
    else
      error "OVERPASS_DB_DIR is set but $OVERPASS_DB_DIR/osm_base_version is missing or empty. Set target_time or OVERPASS_DB_VERSION explicitly."
      usage
      exit 1
    fi
  elif [[ -x "$EXEC_DIR/dispatcher" ]]; then
    DB_DIR=$("$EXEC_DIR/dispatcher" --show-dir 2>/dev/null)
    DB_DIR="$(realpath "$DB_DIR")"
    if [[ -n "$DB_DIR" && -s "$DB_DIR/osm_base_version" ]]; then
      TARGET_TIME=$(cat "$DB_DIR/osm_base_version")
    else
      error "Could not read osm_base_version from dispatcher database directory. Set target_time, OVERPASS_DB_VERSION, or OVERPASS_DB_DIR explicitly."
      usage
      exit 1
    fi
  else
    error "target_time is required (or set OVERPASS_DB_VERSION or OVERPASS_DB_DIR)"
    usage
    exit 1
  fi
fi

if [[ ! "$TARGET_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}\\:[0-9]{2}\\:[0-9]{2}Z$ ]]; then
  error "Invalid target_time '$TARGET_TIME': expected format 2026-03-20T19\:46\:25Z"
  usage
  exit 1
fi

# Validate lower bound
if [[ ! "$LOWER" =~ ^[1-9][0-9]*$ ]]; then
  error "Invalid lower bound '$LOWER': must be a positive integer"
  usage
  exit 1
fi

# Check for curl
if ! command -v curl > /dev/null 2>&1; then
  error "curl is not available"
  exit 1
fi

# Fetch upper bound from source if not specified
if [[ -z "$UPPER" ]]; then
  if ! STATE_TMP=$(mktemp); then
    error "Failed to create temporary file"
    exit 1
  fi
  if curl -fsSL \
    --connect-timeout 30 \
    --retry 3 \
    --retry-delay 5 \
    --retry-all-errors \
    -o "$STATE_TMP" \
    "$SOURCE_URL/state.txt" 2>/dev/null; then
    SEQ_LINE=$(grep -E '^sequenceNumber=[1-9][0-9]*$' "$STATE_TMP")
    if [[ -n "$SEQ_LINE" ]]; then
      UPPER=$(( ${SEQ_LINE#*=} + 0 ))
    fi
  fi
  rm -f "$STATE_TMP"

  if [[ -z "$UPPER" ]]; then
    error "Unable to fetch upper bound from $SOURCE_URL/state.txt"
    exit 1
  fi
fi

# Validate upper bound
if [[ ! "$UPPER" =~ ^[1-9][0-9]*$ ]]; then
  error "Invalid upper bound '$UPPER': must be a positive integer"
  usage
  exit 1
fi

if (( LOWER >= UPPER )); then
  error "lower bound ($LOWER) must be less than upper bound ($UPPER)"
  usage
  exit 1
fi

# ============================================================================
# PATH CONVERSION
# ============================================================================

get_replicate_path() {
  printf '%03u/%03u/%03u' \
    $(( $1 / 1000000 )) \
    $(( ($1 / 1000) % 1000 )) \
    $(( $1 % 1000 ))
}

# ============================================================================
# STATE FILE FETCHING
# ============================================================================

DATA_VERSION=

fetch_state() {
  local TARGET="$1"
  local REPLICATE_PATH LOCAL_PATH LOCAL_FILE REMOTE_URL TMP_FILE TIMESTAMP_LINE HTTP_CODE

  REPLICATE_PATH=$(get_replicate_path "$TARGET")

  LOCAL_PATH="$LOCAL_DIR/${REPLICATE_PATH%/*}"
  LOCAL_FILE="$LOCAL_PATH/${REPLICATE_PATH##*/}.state.txt"
  REMOTE_URL="$SOURCE_URL/$REPLICATE_PATH.state.txt"

  if [[ ! -s "$LOCAL_FILE" ]]; then
    if ! mkdir -p "$LOCAL_PATH"; then
      error "Failed to create directory $LOCAL_PATH"
      DATA_VERSION=
      return 2
    fi

    TMP_FILE="$LOCAL_FILE.tmp"
    HTTP_CODE=$(curl -sSL \
      --connect-timeout 30 \
      --retry 3 \
      --retry-delay 5 \
      -o "$TMP_FILE" \
      --write-out "%{http_code}" \
      "$REMOTE_URL" 2>/dev/null)

    if [[ "$HTTP_CODE" == "404" ]]; then
      warning "Failed to download $REMOTE_URL"
      rm -f "$TMP_FILE"
      DATA_VERSION=
      return 1
    elif [[ "$HTTP_CODE" != "200" || ! -s "$TMP_FILE" ]]; then
      error "Failed to download $REMOTE_URL"
      rm -f "$TMP_FILE"
      DATA_VERSION=
      return 2
    fi

    mv "$TMP_FILE" "$LOCAL_FILE"
  fi

  TIMESTAMP_LINE=$(grep "^timestamp" < "$LOCAL_FILE")
  DATA_VERSION="${TIMESTAMP_LINE:10}"

  if [[ ! "$DATA_VERSION" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}\\:[0-9]{2}\\:[0-9]{2}Z$ ]]; then
    error "Invalid or missing timestamp in $LOCAL_FILE"
    DATA_VERSION=
    return 2
  fi

  return 0
}

# ============================================================================
# BINARY SEARCH
# ============================================================================

while (( LOWER + 1 < UPPER )); do
  TARGET=$(( (LOWER + UPPER) / 2 ))
  fetch_state "$TARGET"
  FETCH_STATUS=$?
  if (( FETCH_STATUS == 2 )); then
    error "Aborting bisect due to download failure"
    exit 1
  elif (( FETCH_STATUS == 1 )); then
    # assume that 404 means that LOWER is less than the starting sequence number
    LOWER="$TARGET"
  elif [[ -n "$DATA_VERSION" && ! "$DATA_VERSION" > "$TARGET_TIME" ]]; then
    LOWER="$TARGET"
  else
    UPPER="$TARGET"
  fi
done

echo "$LOWER"
