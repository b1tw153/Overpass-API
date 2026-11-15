#!/usr/bin/env bash

# Copyright 2026 Kai Johnson
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
# Script: import_osm_data.sh
# Purpose: Downloads and imports an OSM planet file or extract into the
#          Overpass database, then determines the correct replicate_id.
# Note:    This script downloads and imports a planet file or extract and may
#          run for many hours. Run it in the background to prevent
#          interruption:
#
#            nohup ./import_osm_data.sh --db-dir=/opt/overpass/db --diff-dir=/opt/overpass/diff --diff-url=https://... &
# ============================================================================

usage() {
  cat << EOF
Usage: $0 [options]

  --db-dir=DIR                Path to the Overpass database directory (required)
  --diff-dir=DIR              Path to the Overpass diff directory (required)
  --diff-url=URL              URL to the replication source, e.g.:
                              https://planet.openstreetmap.org/replication/minute
  --data-source=URL           URL to the planet or extract file
                              (default: planet-latest.osm.pbf.torrent from
                              planet.openstreetmap.org)
  --meta=yes|no|attic         Metadata mode (default: no)
  --compression-method=METHOD Compression: no|gz|lz4 (default: lz4)

Environment variables:
  OVERPASS_DB_DIR                 Same as --db-dir
  OVERPASS_DIFF_DIR               Same as --diff-dir
  IMPORT_OSM_DATA_SOURCE          Same as --data-source
  OVERPASS_DIFF_URL               Same as --diff-url
  OVERPASS_META_MODE              Same as --meta
  IMPORT_OSM_COMPRESSION_METHOD   Same as --compression-method
  OVERPASS_MIN_FREE_DISK_PERCENT  Minimum free disk space percentage (default: 5)

Supported file formats (detected from URL):
  .osm.bz2.torrent  BitTorrent download, decompressed with bunzip2
  .osm.bz2          HTTP download, decompressed with bunzip2
  .pbf.torrent      BitTorrent download, converted with osmium
  .pbf              HTTP download, converted with osmium
  .osm              HTTP download, no conversion
EOF
}

message() {
  echo "$(date -u '+%F %T'): $1"
}

error() {
  echo "$(date -u '+%F %T'): ERROR: $1" >&2
}

# ============================================================================
# CONFIGURATION
# ============================================================================

DEFAULT_DATA_SOURCE="https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf.torrent"

DB_DIR="${OVERPASS_DB_DIR:-}"
DIFF_DIR="${OVERPASS_DIFF_DIR:-}"
DATA_SOURCE="${IMPORT_OSM_DATA_SOURCE:-$DEFAULT_DATA_SOURCE}"
REPLICATION_SOURCE="${OVERPASS_DIFF_URL:-}"
META="${OVERPASS_META_MODE:-no}"
COMPRESSION="${IMPORT_OSM_COMPRESSION_METHOD:-lz4}"
MIN_FREE_DISK_PERCENT="${OVERPASS_MIN_FREE_DISK_PERCENT:-5}"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

PARSED=$(getopt \
  --options '' \
  --longoptions 'db-dir:,diff-dir:,data-source:,diff-url:,meta:,compression-method:,help' \
  --name "$0" \
  -- "$@") || { usage >&2; exit 1; }

eval set -- "$PARSED"

while true; do
  case "$1" in
    --db-dir)               DB_DIR="$2";               shift 2 ;;
    --diff-dir)             DIFF_DIR="$2";             shift 2 ;;
    --data-source)          DATA_SOURCE="$2";          shift 2 ;;
    --diff-url)             REPLICATION_SOURCE="$2";   shift 2 ;;
    --meta)                 META="$2";                 shift 2 ;;
    --compression-method)   COMPRESSION="$2";          shift 2 ;;
    --help)                 usage; exit 0 ;;
    --)                     shift; break ;;
  esac
done

# ============================================================================
# VALIDATION
# ============================================================================

if [[ -z "$DB_DIR" ]]; then
  error "--db-dir is required (or set OVERPASS_DB_DIR)"
  usage >&2
  exit 1
fi

if [[ -z "$DIFF_DIR" ]]; then
  error "--diff-dir is required (or set OVERPASS_DIFF_DIR)"
  usage >&2
  exit 1
fi

# Resolve both directories to absolute paths before first use. The script
# changes directory later. The -m option allows directories that do not exist yet.
DB_DIR="$(realpath -m "$DB_DIR")"
DIFF_DIR="$(realpath -m "$DIFF_DIR")"

if [[ -z "$REPLICATION_SOURCE" ]]; then
  error "--diff-url is required (or set OVERPASS_DIFF_URL)"
  usage >&2
  exit 1
fi

if ! [[ "$META" =~ ^(yes|no|attic)$ ]]; then
  error "--meta must be 'yes', 'no', or 'attic', got: '$META'"
  exit 1
fi

if ! [[ "$COMPRESSION" =~ ^(no|gz|lz4)$ ]]; then
  error "--compression-method must be 'no', 'gz', or 'lz4', got: '$COMPRESSION'"
  exit 1
fi

if [[ ! "$MIN_FREE_DISK_PERCENT" =~ ^(0|[1-9][0-9]*)$ ]] || (( MIN_FREE_DISK_PERCENT >= 100 )); then
  error "OVERPASS_MIN_FREE_DISK_PERCENT must be an integer from 0 to 99, got: '$MIN_FREE_DISK_PERCENT'"
  exit 1
fi

# ============================================================================
# FILE FORMAT DETECTION
# ============================================================================

# Strip .torrent to get the actual file URL and name
USE_TORRENT=false
FILE_URL="$DATA_SOURCE"
if [[ "$FILE_URL" == *.torrent ]]; then
  USE_TORRENT=true
  FILE_URL="${FILE_URL%.torrent}"
fi

FILENAME=$(basename "$FILE_URL")
MD5_URL="${FILE_URL}.md5"

# Strip .bz2 to detect decompression requirement
USE_BUNZIP2=false
FORMAT_EXT="$FILENAME"
if [[ "$FORMAT_EXT" == *.bz2 ]]; then
  USE_BUNZIP2=true
  FORMAT_EXT="${FORMAT_EXT%.bz2}"
fi

# Detect converter from remaining extension
USE_OSMIUM=false
if [[ "$FORMAT_EXT" == *.pbf ]]; then
  USE_OSMIUM=true
elif [[ "$FORMAT_EXT" == *.osm ]]; then
  : # no conversion needed
else
  error "Unrecognized file format in URL: $DATA_SOURCE - expected .osm, .osm.bz2, .pbf, .osm.bz2.torrent, or .pbf.torrent"
  exit 1
fi

# ============================================================================
# TOOL DETECTION
# ============================================================================

EXEC_DIR="$(dirname "$(realpath "$0")")"

if [[ ! -x "$EXEC_DIR/update_database" ]]; then
  error "update_database not found in $EXEC_DIR"
  exit 1
fi

if [[ ! -x "$EXEC_DIR/bisect_timestamp.sh" ]]; then
  error "bisect_timestamp.sh not found in $EXEC_DIR"
  exit 1
fi

HAS_ARIA2C=false
if command -v aria2c > /dev/null 2>&1; then
  HAS_ARIA2C=true
fi

if [[ "$USE_TORRENT" == "true" && "$HAS_ARIA2C" == "false" ]]; then
  error "aria2c is required for torrent downloads but is not installed"
  exit 1
fi

if [[ "$USE_OSMIUM" == "true" ]] && ! command -v osmium > /dev/null 2>&1; then
  error "osmium is required for .pbf imports but is not installed"
  exit 1
fi

if ! command -v curl > /dev/null 2>&1; then
  error "curl is not available"
  exit 1
fi

if ! command -v md5sum > /dev/null 2>&1; then
  error "md5sum is not available"
  exit 1
fi

# ============================================================================
# SETUP
# ============================================================================

if "$EXEC_DIR/dispatcher" --show-dir > /dev/null 2>&1; then
  error "Dispatcher is running. Stop all Overpass processes before importing."
  exit 1
fi

# The import assumes an empty database. A glob that matches nothing stays
# literal, so -e is false for it and for a missing directory.
for FILE in "$DB_DIR"/*.bin "$DB_DIR"/*.map "$DB_DIR"/*.idx; do
  if [[ -e "$FILE" ]]; then
    error "Database directory $DB_DIR already contains database files (e.g., $FILE). Move or delete them before importing."
    exit 1
  fi
done

if ! mkdir -p "$DB_DIR"; then
  error "Failed to create or access database directory: $DB_DIR"
  exit 1
fi

if ! mkdir -p "$DIFF_DIR"; then
  error "Failed to create or access diff directory: $DIFF_DIR"
  exit 1
fi

# ============================================================================
# DISK SPACE CHECK
# ============================================================================

# Ratios (db_size / source_file_size) derived from planet.openstreetmap.org
# clone and planet file sizes as of 2026-05.  Uses the larger (conservative)
# planet ratio for .bz2 in base/meta modes; switches to the history ratio for
# attic mode.  The .pbf attic ratio is extrapolated from the pbf/bz2 compression
# factor since no history.osm.pbf exists at time of writing.
FILE_SIZE=$(curl -sIL --max-time 30 "$FILE_URL" 2>/dev/null \
  | grep -i "^content-length:" | tail -1 | tr -d ' \r' | cut -d: -f2)

if [[ -z "$FILE_SIZE" || ! "$FILE_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  message "WARNING: Unable to determine source file size; skipping disk space check"
elif [[ "$USE_OSMIUM" == "false" && "$USE_BUNZIP2" == "false" ]]; then
  message "WARNING: Cannot estimate disk space for .osm format; skipping disk space check"
else
  # DB_RATIO is db_size / source_size as an integer percentage
  # (e.g. 315 = database will be approximately 3.15x the source file size)
  if [[ "$USE_OSMIUM" == "true" ]]; then
    case "$META" in
      attic) DB_RATIO=509 ;;  # extrapolated: history.pbf → attic db
      yes)   DB_RATIO=422 ;;  # planet.pbf  → meta db
      *)     DB_RATIO=315 ;;  # planet.pbf  → base db
    esac
  else
    case "$META" in
      attic) DB_RATIO=272 ;;  # history.bz2 → attic db
      yes)   DB_RATIO=226 ;;  # planet.bz2  → meta db  (conservative: planet, not history)
      *)     DB_RATIO=168 ;;  # planet.bz2  → base db  (conservative: planet, not history)
    esac
  fi

  # Threshold: space for source file + database, plus MIN_FREE_DISK_PERCENT headroom
  THRESHOLD=$(( FILE_SIZE * (100 + DB_RATIO) * (100 + MIN_FREE_DISK_PERCENT) / 100 / 100 ))
  FREE_BYTES=$(df --output=avail -B1 "$DB_DIR" | tail -1 | tr -d ' ')
  if (( FREE_BYTES < THRESHOLD )); then
    error "Insufficient free disk space on database filesystem: ${FREE_BYTES} bytes free (minimum: ${THRESHOLD} bytes)"
    exit 1
  fi
fi

# ============================================================================
# DOWNLOAD
# ============================================================================

message "Downloading $FILENAME ..."

cd "$DB_DIR" || exit 1

if [[ "$USE_TORRENT" == "true" ]]; then
  aria2c --allow-overwrite=true --seed-time=0 -o "$FILENAME" "$DATA_SOURCE" \
    || { error "Download failed"; exit 1; }
elif [[ "$HAS_ARIA2C" == "true" ]]; then
  aria2c --allow-overwrite=true -x 16 -s 16 -o "$FILENAME" "$FILE_URL" \
    || { error "Download failed"; exit 1; }
else
  curl -f -S -L \
    --retry 10 \
    --retry-delay 30 \
    --speed-limit 1024 \
    --speed-time 60 \
    -o "$FILENAME" \
    "$FILE_URL" \
    || { error "Download failed"; exit 1; }
fi

message "Download complete"

# Fetch the MD5 checksum.  The .md5 is tiny, so always use curl (a guaranteed
# dependency) rather than aria2c, which lets us inspect the HTTP status code.
# Some extract providers (e.g. download.openstreetmap.fr) do not publish .md5
# files; a 404 there is expected and only a warning.  Any other failure is an
# error.
HTTP_CODE=$(curl -s -S -L \
  --retry 10 \
  --retry-delay 30 \
  --speed-limit 1024 \
  --speed-time 60 \
  -o "$FILENAME.md5" \
  -w '%{http_code}' \
  "$MD5_URL")
CURL_STATUS=$?

# ============================================================================
# MD5 VERIFICATION
# ============================================================================

if (( CURL_STATUS != 0 )); then
  error "Failed to download MD5 checksum from $MD5_URL (curl exit $CURL_STATUS)"
  exit 1
elif [[ "$HTTP_CODE" == "404" ]]; then
  rm -f "$FILENAME.md5"
  message "WARNING: No MD5 checksum available for $FILENAME (HTTP 404); skipping verification"
elif [[ "$HTTP_CODE" != "200" ]]; then
  rm -f "$FILENAME.md5"
  error "Failed to download MD5 checksum from $MD5_URL (HTTP $HTTP_CODE)"
  exit 1
else
  message "Verifying MD5 checksum ..."
  if ! md5sum -c "${FILENAME}.md5"; then
    error "MD5 verification failed for $FILENAME"
    exit 1
  fi
  message "Verified MD5 checksum"
fi

# ============================================================================
# IMPORT
# ============================================================================

case "$META" in
  yes)   META_FLAG="--meta" ;;
  attic) META_FLAG="--keep-attic" ;;
  *)     META_FLAG="--data-only" ;;
esac

message "Importing $FILENAME into database ..."

if [[ "$USE_BUNZIP2" == "true" ]]; then
  bunzip2 <"$DB_DIR/$FILENAME" \
    | "$EXEC_DIR/update_database" \
        --db-dir="$DB_DIR" \
        "$META_FLAG" \
        --compression-method="$COMPRESSION" \
        --map-compression-method="$COMPRESSION"
elif [[ "$USE_OSMIUM" == "true" ]]; then
  osmium cat -f osm "$DB_DIR/$FILENAME" \
    | "$EXEC_DIR/update_database" \
        --db-dir="$DB_DIR" \
        "$META_FLAG" \
        --compression-method="$COMPRESSION" \
        --map-compression-method="$COMPRESSION"
else
  "$EXEC_DIR/update_database" \
    --db-dir="$DB_DIR" \
    "$META_FLAG" \
    --compression-method="$COMPRESSION" \
    --map-compression-method="$COMPRESSION" \
    < "$DB_DIR/$FILENAME"
fi

PIPE_STATUS=("${PIPESTATUS[@]}")
if [[ "$USE_BUNZIP2" == "true" || "$USE_OSMIUM" == "true" ]]; then
  if (( ${PIPE_STATUS[0]:-0} != 0 )); then
    if [[ "$USE_BUNZIP2" == "true" ]]; then
      error "bunzip2 failed (exit code ${PIPE_STATUS[0]})"
    else
      error "osmium failed (exit code ${PIPE_STATUS[0]})"
    fi
    exit 1
  fi
  if (( ${PIPE_STATUS[1]:-0} != 0 )); then
    error "update_database failed (exit code ${PIPE_STATUS[1]})"
    exit 1
  fi
else
  if (( ${PIPE_STATUS[0]:-0} != 0 )); then
    error "update_database failed (exit code ${PIPE_STATUS[0]})"
    exit 1
  fi
fi

message "Database import complete"

# ============================================================================
# REPLICATE ID
# ============================================================================

message "Finding replicate_id for $REPLICATION_SOURCE ..."

if OUTPUT=$(OVERPASS_DB_DIR="$DB_DIR" "$EXEC_DIR/bisect_timestamp.sh" "$REPLICATION_SOURCE" "$DIFF_DIR"); then
  message "REPLICATE_ID=$OUTPUT"
  echo "$OUTPUT" > "$DB_DIR/replicate_id"
else
  error "Unable to determine replicate_id"
  exit 1
fi

message "Database ready"
