#!/usr/bin/env bash

# Copyright 2026 Kai Johnson
#
# This file is part of Overpass_API.
#
# USAGE NOTE: This script downloads and imports a planet file or extract and
# may run for many hours. Run it in the background to prevent interruption:
#
#   nohup ./import_osm_data.sh --db-dir=/opt/overpass/db --diff-dir=/opt/overpass/diff --diff-url=https://... &
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
# ============================================================================

usage()
{
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

message()
{
  echo "$(date -u '+%F %T'): $1"
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
  -- "$@") || { usage; exit 1; }

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
  message "ERROR: --db-dir is required (or set OVERPASS_DB_DIR)"
  usage
  exit 1
fi

if [[ -z "$DIFF_DIR" ]]; then
  message "ERROR: --diff-dir is required (or set OVERPASS_DIFF_DIR)"
  usage
  exit 1
fi

if [[ -z "$REPLICATION_SOURCE" ]]; then
  message "ERROR: --diff-url is required (or set OVERPASS_DIFF_URL)"
  usage
  exit 1
fi

if ! [[ "$META" =~ ^(yes|no|attic)$ ]]; then
  message "ERROR: Invalid value for --meta: $META (expected yes, no, or attic)"
  exit 1
fi

if ! [[ "$COMPRESSION" =~ ^(no|gz|lz4)$ ]]; then
  message "ERROR: Invalid value for --compression-method: $COMPRESSION (expected no, gz, or lz4)"
  exit 1
fi

if [[ ! "$MIN_FREE_DISK_PERCENT" =~ ^[0-9]+$ || $MIN_FREE_DISK_PERCENT -ge 100 ]]; then
  message "ERROR: Invalid value for OVERPASS_MIN_FREE_DISK_PERCENT: $MIN_FREE_DISK_PERCENT (expected integer 0-99)"
  exit 1
fi

# ============================================================================
# FILE FORMAT DETECTION
# ============================================================================

# Strip .torrent to get the actual file URL and name
USE_TORRENT=0
FILE_URL="$DATA_SOURCE"
if [[ "$FILE_URL" == *.torrent ]]; then
  USE_TORRENT=1
  FILE_URL="${FILE_URL%.torrent}"
fi

FILENAME=$(basename "$FILE_URL")
MD5_URL="${FILE_URL}.md5"

# Strip .bz2 to detect decompression requirement
USE_BUNZIP2=0
FORMAT_EXT="$FILENAME"
if [[ "$FORMAT_EXT" == *.bz2 ]]; then
  USE_BUNZIP2=1
  FORMAT_EXT="${FORMAT_EXT%.bz2}"
fi

# Detect converter from remaining extension
USE_OSMIUM=0
if [[ "$FORMAT_EXT" == *.pbf ]]; then
  USE_OSMIUM=1
elif [[ "$FORMAT_EXT" == *.osm ]]; then
  : # no conversion needed
else
  message "ERROR: Unrecognized file format in URL: $DATA_SOURCE"
  message "       Expected .osm, .osm.bz2, .pbf, .osm.bz2.torrent, or .pbf.torrent"
  exit 1
fi

# ============================================================================
# TOOL DETECTION
# ============================================================================

EXEC_DIR="$(dirname "$(realpath "$0")")"

if [[ ! -x "$EXEC_DIR/update_database" ]]; then
  message "ERROR: update_database not found in $EXEC_DIR"
  exit 1
fi

if [[ ! -x "$EXEC_DIR/bisect_timestamp.sh" ]]; then
  message "ERROR: bisect_timestamp.sh not found in $EXEC_DIR"
  exit 1
fi

HAS_ARIA2C=0
if command -v aria2c > /dev/null 2>&1; then
  HAS_ARIA2C=1
fi

if [[ $USE_TORRENT -eq 1 && $HAS_ARIA2C -eq 0 ]]; then
  message "ERROR: aria2c is required for torrent downloads but is not installed"
  exit 1
fi

if [[ $USE_OSMIUM -eq 1 ]] && ! command -v osmium > /dev/null 2>&1; then
  message "ERROR: osmium is required for .pbf imports but is not installed"
  exit 1
fi

if ! command -v md5sum > /dev/null 2>&1; then
  message "ERROR: md5sum is not available"
  exit 1
fi

# ============================================================================
# SETUP
# ============================================================================

if ! mkdir -p "$DB_DIR"; then
  message "ERROR: Failed to create or access database directory: $DB_DIR"
  exit 1
fi

if ! mkdir -p "$DIFF_DIR"; then
  message "ERROR: Failed to create or access diff directory: $DIFF_DIR"
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

if [[ -z "$FILE_SIZE" || ! "$FILE_SIZE" =~ ^[0-9]+$ ]]; then
  message "WARNING: Unable to determine source file size; skipping disk space check"
elif [[ $USE_OSMIUM -eq 0 && $USE_BUNZIP2 -eq 0 ]]; then
  message "WARNING: Cannot estimate disk space for .osm format; skipping disk space check"
else
  # DB_RATIO is db_size / source_size as an integer percentage
  # (e.g. 315 = database will be approximately 3.15x the source file size)
  if [[ $USE_OSMIUM -eq 1 ]]; then
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
  if [[ $FREE_BYTES -lt $THRESHOLD ]]; then
    message "ERROR: Insufficient free disk space on database filesystem: ${FREE_BYTES} bytes free (minimum: ${THRESHOLD} bytes)"
    exit 1
  fi
fi

# ============================================================================
# DOWNLOAD
# ============================================================================

message "Downloading $FILENAME ..."

cd "$DB_DIR" || exit 1

if [[ $USE_TORRENT -eq 1 ]]; then
  aria2c --allow-overwrite=true --seed-time=0 -o "$FILENAME" "$DATA_SOURCE" \
    || { message "ERROR: Download failed"; exit 1; }
elif [[ $HAS_ARIA2C -eq 1 ]]; then
  aria2c --allow-overwrite=true -x 16 -s 16 -o "$FILENAME" "$FILE_URL" \
    || { message "ERROR: Download failed"; exit 1; }
else
  curl -f -S -L \
    --retry 10 \
    --retry-delay 30 \
    --speed-limit 1024 \
    --speed-time 60 \
    -o "$FILENAME" \
    "$FILE_URL" \
    || { message "ERROR: Download failed"; exit 1; }
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

if [[ $CURL_STATUS -ne 0 ]]; then
  message "ERROR: Failed to download MD5 checksum from $MD5_URL (curl exit $CURL_STATUS)"
  exit 1
elif [[ "$HTTP_CODE" == 404 ]]; then
  rm -f "$FILENAME.md5"
  message "WARNING: No MD5 checksum available for $FILENAME (HTTP 404); skipping verification"
elif [[ "$HTTP_CODE" != 200 ]]; then
  rm -f "$FILENAME.md5"
  message "ERROR: Failed to download MD5 checksum from $MD5_URL (HTTP $HTTP_CODE)"
  exit 1
else
  message "Verifying MD5 checksum ..."
  if ! md5sum -c "${FILENAME}.md5"; then
    message "ERROR: MD5 verification failed for $FILENAME"
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

if [[ $USE_BUNZIP2 -eq 1 ]]; then
  bunzip2 <"$DB_DIR/$FILENAME" \
    | "$EXEC_DIR/update_database" \
        --db-dir="$DB_DIR" \
        "$META_FLAG" \
        --compression-method="$COMPRESSION" \
        --map-compression-method="$COMPRESSION"
elif [[ $USE_OSMIUM -eq 1 ]]; then
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
if [[ $USE_BUNZIP2 -eq 1 || $USE_OSMIUM -eq 1 ]]; then
  if [[ ${PIPE_STATUS[0]:-0} -ne 0 ]]; then
    if [[ $USE_BUNZIP2 -eq 1 ]]; then
      message "ERROR: bunzip2 failed (exit code ${PIPE_STATUS[0]})"
    else
      message "ERROR: osmium failed (exit code ${PIPE_STATUS[0]})"
    fi
    exit 1
  fi
  if [[ ${PIPE_STATUS[1]:-0} -ne 0 ]]; then
    message "ERROR: update_database failed (exit code ${PIPE_STATUS[1]})"
    exit 1
  fi
else
  if [[ ${PIPE_STATUS[0]:-0} -ne 0 ]]; then
    message "ERROR: update_database failed (exit code ${PIPE_STATUS[0]})"
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
  message "ERROR: Unable to determine replicate_id:"
  message "$OUTPUT"
  exit 1
fi

message "Database ready"
