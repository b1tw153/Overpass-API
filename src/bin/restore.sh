#!/usr/bin/env bash

# Copyright 2025, 2026 Kai Johnson
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
# Script: restore.sh
# Purpose: Restores the Overpass database from a backup. Requires all Overpass
#          processes to be stopped
# ============================================================================

usage() {
  cat >&2 << EOF
Usage: $0 backup_dir db_dir

  backup_dir    Source directory containing backup files
  db_dir        Target database directory

Environment variables:
  OVERPASS_RESTORE_TIMEOUT    Restore timeout in seconds (default: 7200)
EOF
}

if [[ -z "${2:-}" ]]; then
  usage
  exit 1
fi

EXEC_DIR="$(dirname "$(realpath "$0")")"

DB_DIR="$(realpath "$2")"

if ! [[ -d $DB_DIR && -w $DB_DIR ]]; then
  echo "ERROR: Database directory '$DB_DIR' is not a writeable directory" >&2
  exit 1
fi

BACKUP_DIR="$(realpath "$1")"

if ! [[ -d $BACKUP_DIR && -r $BACKUP_DIR ]]; then
  echo "ERROR: Backup directory '$BACKUP_DIR' is not a readable directory" >&2
  exit 1
fi

if "$EXEC_DIR/dispatcher" --show-dir > /dev/null 2>&1; then
  echo "ERROR: Dispatcher is running; stop all Overpass processes before restoring" >&2
  exit 1
fi

RESTORE_TIMEOUT=${OVERPASS_RESTORE_TIMEOUT:-7200}

if [[ ! "$RESTORE_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: OVERPASS_RESTORE_TIMEOUT must be a positive integer, got: '$RESTORE_TIMEOUT'" >&2
  exit 1
fi

# Log file
LOG_FILE="$DB_DIR/backup.log"

# ============================================================================
# LOGGING
# ============================================================================

log_message() {
  if [[ -t 1 ]]; then
    echo "$(date -u '+%F %T'): $1" | tee -a "$LOG_FILE"
  else
    echo "$(date -u '+%F %T'): $1" >> "$LOG_FILE"
  fi
}

log_error() {
  if [[ -t 2 ]]; then
    echo "$(date -u '+%F %T'): ERROR: $1" | tee -a "$LOG_FILE" >&2
  else
    echo "$(date -u '+%F %T'): ERROR: $1" >> "$LOG_FILE"
  fi
}

# ============================================================================
# DATABASE FILES
# ============================================================================

FILES_BASE=(
  nodes.bin nodes.bin.idx nodes.map nodes.map.idx
  node_tags_local.bin node_tags_local.bin.idx node_tags_global.bin node_tags_global.bin.idx
  node_frequent_tags.bin node_frequent_tags.bin.idx node_keys.bin node_keys.bin.idx
  ways.bin ways.bin.idx ways.map ways.map.idx
  way_tags_local.bin way_tags_local.bin.idx way_tags_global.bin way_tags_global.bin.idx
  way_frequent_tags.bin way_frequent_tags.bin.idx way_keys.bin way_keys.bin.idx
  relations.bin relations.bin.idx relations.map relations.map.idx
  relation_roles.bin relation_roles.bin.idx
  relation_tags_local.bin relation_tags_local.bin.idx relation_tags_global.bin relation_tags_global.bin.idx
  relation_frequent_tags.bin relation_frequent_tags.bin.idx relation_keys.bin relation_keys.bin.idx
  osm_base_version
)

# Files that a valid backup may omit. The restore copies each one that the
# backup has and removes each one that it omits, so that the database matches
# the backup. The `base-url` file exists only in a database made by
# download_clone.sh. The `replicate_id` file is written by apply_osc_to_db.sh.
FILES_OPTIONAL=(
  base-url replicate_id
)

FILES_META=(
  nodes_meta.bin nodes_meta.bin.idx
  ways_meta.bin ways_meta.bin.idx
  relations_meta.bin relations_meta.bin.idx
  user_data.bin user_data.bin.idx user_indices.bin user_indices.bin.idx
)

FILES_ATTIC=(
  nodes_attic.bin nodes_attic.bin.idx nodes_attic.map nodes_attic.map.idx
  node_attic_indexes.bin node_attic_indexes.bin.idx
  nodes_attic_undeleted.bin nodes_attic_undeleted.bin.idx
  nodes_meta_attic.bin nodes_meta_attic.bin.idx
  node_changelog.bin node_changelog.bin.idx
  node_tags_local_attic.bin node_tags_local_attic.bin.idx
  node_tags_global_attic.bin node_tags_global_attic.bin.idx
  node_frequent_tags_attic.bin node_frequent_tags_attic.bin.idx
  ways_attic.bin ways_attic.bin.idx ways_attic.map ways_attic.map.idx
  way_attic_indexes.bin way_attic_indexes.bin.idx
  ways_attic_undeleted.bin ways_attic_undeleted.bin.idx
  ways_meta_attic.bin ways_meta_attic.bin.idx
  way_changelog.bin way_changelog.bin.idx
  way_tags_local_attic.bin way_tags_local_attic.bin.idx
  way_tags_global_attic.bin way_tags_global_attic.bin.idx
  way_frequent_tags_attic.bin way_frequent_tags_attic.bin.idx
  relations_attic.bin relations_attic.bin.idx relations_attic.map relations_attic.map.idx
  relation_attic_indexes.bin relation_attic_indexes.bin.idx
  relations_attic_undeleted.bin relations_attic_undeleted.bin.idx
  relations_meta_attic.bin relations_meta_attic.bin.idx
  relation_changelog.bin relation_changelog.bin.idx
  relation_tags_local_attic.bin relation_tags_local_attic.bin.idx
  relation_tags_global_attic.bin relation_tags_global_attic.bin.idx
  relation_frequent_tags_attic.bin relation_frequent_tags_attic.bin.idx
)

FILES_AREAS=(
  area_blocks.bin area_blocks.bin.idx
  areas.bin areas.bin.idx
  area_tags_global.bin area_tags_global.bin.idx
  area_tags_local.bin area_tags_local.bin.idx
  area_version
)

# ============================================================================
# LOCK CHECK
# ============================================================================

check_lock_files() {
  local LOCK_FILE PID
  for LOCK_FILE in "$DB_DIR/osm_base_shadow.lock" "$DB_DIR/areas_shadow.lock"; do
    [[ -f "$LOCK_FILE" ]] || continue

    PID=$(< "$LOCK_FILE")
    if [[ "$PID" =~ ^[1-9][0-9]*$ ]] && kill -0 "$PID" 2>/dev/null; then
      log_error "Lock file '$LOCK_FILE' is held by live process (PID $PID)"
      return 1
    fi
  done
  return 0
}

# ============================================================================
# DATABASE STATE DETECTION
# ============================================================================

# Print the meta mode of the database in directory $1: no, yes or attic.
# Return 1 and print nothing if nodes.bin, ways.bin or relations.bin is
# missing. Return 2 if $1 is not a directory.
detect_database_meta_state() {
  local DIR="$1"
  local TRUNK

  if [[ ! -d "$DIR" ]]; then
    log_error "detect_database_meta_state: not a directory: '$DIR'"
    return 2
  fi

  for TRUNK in nodes ways relations; do
    [[ -f "$DIR/$TRUNK.bin" ]] || return 1
  done

  local ATTIC_TRUNKS=(
    nodes_attic nodes_attic_undeleted node_attic_indexes
    node_tags_local_attic node_tags_global_attic node_frequent_tags_attic
    nodes_meta_attic node_changelog
    ways_attic ways_attic_undeleted way_attic_indexes
    way_tags_local_attic way_tags_global_attic way_frequent_tags_attic
    ways_meta_attic way_changelog
    relations_attic relations_attic_undeleted relation_attic_indexes
    relation_tags_local_attic relation_tags_global_attic
    relation_frequent_tags_attic relations_meta_attic relation_changelog
  )
  local META_TRUNKS=(
    user_data user_indices nodes_meta ways_meta relations_meta
  )

  for TRUNK in "${ATTIC_TRUNKS[@]}"; do
    if [[ -f "$DIR/$TRUNK.bin" ]]; then
      echo "attic"
      return 0
    fi
  done
  for TRUNK in "${META_TRUNKS[@]}"; do
    if [[ -f "$DIR/$TRUNK.bin" ]]; then
      echo "yes"
      return 0
    fi
  done
  echo "no"
}

# Print whether the database in directory $1 has area files: yes or no.
# Return 1 and print nothing if only some of the four area files exist.
# Return 2 if $1 is not a directory.
detect_database_areas() {
  local DIR="$1"
  local TRUNK
  local FOUND=0
  local AREA_TRUNKS=(area_blocks areas area_tags_local area_tags_global)

  if [[ ! -d "$DIR" ]]; then
    log_error "detect_database_areas: not a directory: '$DIR'"
    return 2
  fi

  for TRUNK in "${AREA_TRUNKS[@]}"; do
    if [[ -f "$DIR/$TRUNK.bin" ]]; then
      (( ++FOUND ))
    fi
  done

  if (( FOUND == 0 )); then
    echo "no"
  elif (( FOUND == ${#AREA_TRUNKS[@]} )); then
    echo "yes"
  else
    log_error "Incomplete area files in '$DIR' ($FOUND of ${#AREA_TRUNKS[@]})"
    return 1
  fi
}

# ============================================================================
# RESTORE FILES
# ============================================================================

restore_files() {
  local exit_code
  printf '%s\n' "$@" \
    | timeout "$RESTORE_TIMEOUT" rsync -a --files-from=- "$BACKUP_DIR/" "$DB_DIR/"
  exit_code=$?
  if (( exit_code == 124 )); then
    log_error "rsync timed out after ${RESTORE_TIMEOUT}s"
    return 1
  elif (( exit_code != 0 )); then
    log_error "rsync failed (exit $exit_code)"
    return 1
  fi
}

# Make the optional files in DB_DIR match the backup. Copy each file that
# BACKUP_DIR has. Remove each file that BACKUP_DIR omits.
# $@: names of the files
# Returns 1 if a file can't be removed or the copy fails.
restore_optional_files() {
  local files=()
  local f
  for f in "$@"; do
    if [[ -e "$BACKUP_DIR/$f" ]]; then
      files+=("$f")
    elif [[ -e "$DB_DIR/$f" ]]; then
      log_message "Removing '$f' because the backup omits it"
      rm -f "$DB_DIR/$f" || { log_error "Unable to remove '$DB_DIR/$f'"; return 1; }
    fi
  done
  (( ${#files[@]} > 0 )) || return 0
  restore_files "${files[@]}"
}

# Check that the backup holds every file in the list.
# $@: names of the files in BACKUP_DIR
# Returns 1 and logs each missing file if any is absent.
check_backup_complete() {
  local missing=false
  local f
  for f in "$@"; do
    if [[ ! -e "$BACKUP_DIR/$f" ]]; then
      log_error "Backup is incomplete: required file '$f' is missing from '$BACKUP_DIR'"
      missing=true
    fi
  done
  [[ "$missing" == "false" ]]
}

# ============================================================================
# TRANSACTION LEFTOVERS
# ============================================================================

# Remove the files that a write transaction or a migration leaves behind when
# it doesn't finish. A dispatcher that finds a commit marker copies the shadow
# index files over the main index files, which would overwrite the restored
# files. Leave the `.status` file alone. It is not a transaction file.
# Returns 1 if a file can't be removed.
remove_transaction_leftovers() {
  local leftovers=()
  local f
  mapfile -t leftovers < <(find "$DB_DIR" -maxdepth 1 -type f \( \
    -name 'osm_base_shadow' -o -name 'areas_shadow' \
    -o -name 'osm_base_shadow.lock' -o -name 'areas_shadow.lock' \
    -o -name 'osm_base_shadow.next' -o -name 'areas_shadow.next' \
    -o -name '*.shadow' \
    -o -name '*.next.bin' -o -name '*.next.bin.idx' \
    -o -name '*.next.map' -o -name '*.next.map.idx' \))
  for f in "${leftovers[@]}"; do
    log_message "Removing transaction leftover '$f'"
    rm -f "$f" || { log_error "Unable to remove '$f'"; return 1; }
  done
}

# ============================================================================
# COMPATIBILITY CHECK
# ============================================================================

meta_level() {
  case "$1" in
    no)    echo 0 ;;
    yes)   echo 1 ;;
    attic) echo 2 ;;
  esac
}

check_db_compatible() {
  local BACKUP_META="$1"
  local DB_META
  DB_META=$(detect_database_meta_state "$DB_DIR") || return 0  # uninitialized is always ok

  if (( $(meta_level "$DB_META") > $(meta_level "$BACKUP_META") )); then
    log_error "Database has meta=$DB_META but backup has meta=$BACKUP_META; restoring would leave orphaned files"
    return 1
  fi

  local DB_AREAS
  local BACKUP_AREAS
  DB_AREAS=$(detect_database_areas "$DB_DIR") || return 1
  BACKUP_AREAS=$(detect_database_areas "$BACKUP_DIR") || return 1

  if [[ "$DB_AREAS" == "yes" && "$BACKUP_AREAS" == "no" ]]; then
    log_error "Database has areas files but backup does not; restoring would leave orphaned files"
    return 1
  fi

  return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

if ! command -v rsync > /dev/null 2>&1; then
  echo "ERROR: rsync is not available" >&2
  exit 1
fi

log_message "-----------------------------------"
log_message "Starting Restore Process ($0)"
log_message "-----------------------------------"
log_message "backup_dir                         $BACKUP_DIR"
log_message "db_dir                             $DB_DIR"
log_message "OVERPASS_RESTORE_TIMEOUT           $RESTORE_TIMEOUT"
log_message "-----------------------------------"

check_lock_files || exit 1

META_STATE=$(detect_database_meta_state "$BACKUP_DIR") \
  || { log_error "Backup is not valid (missing base files)"; exit 1; }

check_db_compatible "$META_STATE" || exit 1

RESTORE_AREAS=$(detect_database_areas "$BACKUP_DIR") || exit 1

# Check the whole backup before changing the database. A restore that fails
# partway leaves the database with a mix of old and new files.
REQUIRED_FILES=("${FILES_BASE[@]}")
if [[ "$META_STATE" == "yes" || "$META_STATE" == "attic" ]]; then
  REQUIRED_FILES+=("${FILES_META[@]}")
fi
if [[ "$META_STATE" == "attic" ]]; then
  REQUIRED_FILES+=("${FILES_ATTIC[@]}")
fi
if [[ "$RESTORE_AREAS" == "yes" ]]; then
  REQUIRED_FILES+=("${FILES_AREAS[@]}")
fi
check_backup_complete "${REQUIRED_FILES[@]}" || exit 1

log_message "Restore started (meta=$META_STATE)"

remove_transaction_leftovers || exit 1

log_message "Restoring base files"
restore_files "${FILES_BASE[@]}" || exit 1
restore_optional_files "${FILES_OPTIONAL[@]}" || exit 1

if [[ "$META_STATE" == "yes" || "$META_STATE" == "attic" ]]; then
  log_message "Restoring meta files"
  restore_files "${FILES_META[@]}" || exit 1
fi

if [[ "$META_STATE" == "attic" ]]; then
  log_message "Restoring attic files"
  restore_files "${FILES_ATTIC[@]}" || exit 1
fi

if [[ "$RESTORE_AREAS" == "yes" ]]; then
  log_message "Restoring area files"
  restore_files "${FILES_AREAS[@]}" || exit 1
fi

log_message "Restore complete"
