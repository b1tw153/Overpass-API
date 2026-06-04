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
# Restore script for Overpass API
# Restores database from backup; requires all Overpass processes to be stopped
# ============================================================================

usage()
{
  cat << EOF
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

EXEC_DIR="$(realpath "$(dirname "$0")")"

DB_DIR="$(realpath "$2")"

if ! [[ -d $DB_DIR && -w $DB_DIR ]]; then
  echo "ERROR: Database directory '$DB_DIR' is not a writeable directory"
  exit 1
fi

BACKUP_DIR="$(realpath "$1")"

if ! [[ -d $BACKUP_DIR && -r $BACKUP_DIR ]]; then
  echo "ERROR: Backup directory '$BACKUP_DIR' is not a readable directory"
  exit 1
fi

if "$EXEC_DIR/dispatcher" --show-dir > /dev/null 2>&1; then
  echo "ERROR: Dispatcher is running; stop all Overpass processes before restoring"
  exit 1
fi

RESTORE_TIMEOUT=${OVERPASS_RESTORE_TIMEOUT:-7200}

# Log file
LOG_FILE="$DB_DIR/backup.log"

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
# DATABASE FILES
# ============================================================================

FILES_BASE="\
nodes.bin nodes.bin.idx nodes.map nodes.map.idx \
node_tags_local.bin node_tags_local.bin.idx node_tags_global.bin node_tags_global.bin.idx \
node_frequent_tags.bin node_frequent_tags.bin.idx node_keys.bin node_keys.bin.idx \
ways.bin ways.bin.idx ways.map ways.map.idx \
way_tags_local.bin way_tags_local.bin.idx way_tags_global.bin way_tags_global.bin.idx \
way_frequent_tags.bin way_frequent_tags.bin.idx way_keys.bin way_keys.bin.idx \
relations.bin relations.bin.idx relations.map relations.map.idx \
relation_roles.bin relation_roles.bin.idx \
relation_tags_local.bin relation_tags_local.bin.idx relation_tags_global.bin relation_tags_global.bin.idx \
relation_frequent_tags.bin relation_frequent_tags.bin.idx relation_keys.bin relation_keys.bin.idx \
osm_base_version replicate_id"

FILES_META="\
nodes_meta.bin nodes_meta.bin.idx \
ways_meta.bin ways_meta.bin.idx \
relations_meta.bin relations_meta.bin.idx \
user_data.bin user_data.bin.idx user_indices.bin user_indices.bin.idx"

FILES_ATTIC="\
nodes_attic.bin nodes_attic.bin.idx nodes_attic.map nodes_attic.map.idx \
node_attic_indexes.bin node_attic_indexes.bin.idx \
nodes_attic_undeleted.bin nodes_attic_undeleted.bin.idx \
nodes_meta_attic.bin nodes_meta_attic.bin.idx \
node_changelog.bin node_changelog.bin.idx \
node_tags_local_attic.bin node_tags_local_attic.bin.idx \
node_tags_global_attic.bin node_tags_global_attic.bin.idx \
node_frequent_tags_attic.bin node_frequent_tags_attic.bin.idx \
ways_attic.bin ways_attic.bin.idx ways_attic.map ways_attic.map.idx \
way_attic_indexes.bin way_attic_indexes.bin.idx \
ways_attic_undeleted.bin ways_attic_undeleted.bin.idx \
ways_meta_attic.bin ways_meta_attic.bin.idx \
way_changelog.bin way_changelog.bin.idx \
way_tags_local_attic.bin way_tags_local_attic.bin.idx \
way_tags_global_attic.bin way_tags_global_attic.bin.idx \
way_frequent_tags_attic.bin way_frequent_tags_attic.bin.idx \
relations_attic.bin relations_attic.bin.idx relations_attic.map relations_attic.map.idx \
relation_attic_indexes.bin relation_attic_indexes.bin.idx \
relations_attic_undeleted.bin relations_attic_undeleted.bin.idx \
relations_meta_attic.bin relations_meta_attic.bin.idx \
relation_changelog.bin relation_changelog.bin.idx \
relation_tags_local_attic.bin relation_tags_local_attic.bin.idx \
relation_tags_global_attic.bin relation_tags_global_attic.bin.idx \
relation_frequent_tags_attic.bin relation_frequent_tags_attic.bin.idx"

FILES_AREAS="\
area_blocks.bin area_blocks.bin.idx \
areas.bin areas.bin.idx \
area_tags_global.bin area_tags_global.bin.idx \
area_tags_local.bin area_tags_local.bin.idx \
area_version"

# ============================================================================
# LOCK CHECK
# ============================================================================

check_lock_files()
{
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

# Detect the meta mode of a database directory by checking for characteristic files
# $1: directory to inspect
# Returns: "no", "yes", or "attic" via stdout
# Returns 1 if base files are missing (not a valid backup)
detect_database_meta_state()
{
  local DIR="$1"

  # Check for attic files (most specific check first)
  if [[ -f "$DIR/nodes_attic.bin" || -f "$DIR/node_changelog.bin" || -f "$DIR/ways_attic.bin" ]]; then
    echo "attic"
    return 0
  fi

  # Check for meta files
  if [[ -f "$DIR/nodes_meta.bin" || -f "$DIR/ways_meta.bin" || -f "$DIR/user_data.bin" ]]; then
    echo "yes"
    return 0
  fi

  # No meta or attic files found - verify base files exist
  if [[ ! -f "$DIR/nodes.bin" || ! -f "$DIR/ways.bin" || ! -f "$DIR/relations.bin" ]]; then
    return 1
  fi

  echo "no"
  return 0
}

detect_database_areas()
{
  local DIR="$1"

  if [[ -f "$DIR/areas.bin" && -f "$DIR/area_blocks.bin" && -f "$DIR/area_tags_global.bin" && -f "$DIR/area_tags_local.bin" ]]; then
    return 0
  fi
  return 1
}

# ============================================================================
# RESTORE FILES
# ============================================================================

restore_files()
{
  local exit_code
  # shellcheck disable=SC2068
  printf '%s\n' $@ \
    | timeout "$RESTORE_TIMEOUT" rsync -a --files-from=- "$BACKUP_DIR/" "$DB_DIR/"
  exit_code=$?
  if [[ $exit_code -eq 124 ]]; then
    log_error "rsync timed out after ${RESTORE_TIMEOUT}s"
    return 1
  elif [[ $exit_code -ne 0 ]]; then
    log_error "rsync failed (exit $exit_code)"
    return 1
  fi
}

# ============================================================================
# COMPATIBILITY CHECK
# ============================================================================

meta_level()
{
  case "$1" in
    no)    echo 0 ;;
    yes)   echo 1 ;;
    attic) echo 2 ;;
  esac
}

check_db_compatible()
{
  local BACKUP_META="$1"
  local DB_META
  DB_META=$(detect_database_meta_state "$DB_DIR") || return 0  # uninitialized is always ok

  if (( $(meta_level "$DB_META") > $(meta_level "$BACKUP_META") )); then
    log_error "Database has meta=$DB_META but backup has meta=$BACKUP_META; restoring would leave orphaned files"
    return 1
  fi

  if detect_database_areas "$DB_DIR" && ! detect_database_areas "$BACKUP_DIR"; then
    log_error "Database has areas files but backup does not; restoring would leave orphaned files"
    return 1
  fi

  return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

check_lock_files || exit 1

META_STATE=$(detect_database_meta_state "$BACKUP_DIR") \
  || { log_error "Backup is not valid (missing base files)"; exit 1; }

check_db_compatible "$META_STATE" || exit 1

log_message "Restore started (meta=$META_STATE)"

log_message "Restoring base files"
# shellcheck disable=SC2086
restore_files $FILES_BASE || exit 1

if [[ "$META_STATE" == "yes" || "$META_STATE" == "attic" ]]; then
  log_message "Restoring meta files"
  # shellcheck disable=SC2086
  restore_files $FILES_META || exit 1
fi

if [[ "$META_STATE" == "attic" ]]; then
  log_message "Restoring attic files"
  # shellcheck disable=SC2086
  restore_files $FILES_ATTIC || exit 1
fi

if detect_database_areas "$BACKUP_DIR"; then
  log_message "Restoring area files"
  # shellcheck disable=SC2086
  restore_files $FILES_AREAS || exit 1
fi

log_message "Restore complete"
