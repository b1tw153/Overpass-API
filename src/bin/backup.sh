#!/usr/bin/env bash

# Robust backup script for Overpass API v0.7.61.4
# Performs safe backup with process verification and error handling

if [[ -z $1 ]]; then
{
  echo "Usage: $0 backup_dir"
  echo ""
  echo "  backup_dir: Target directory for backup files"
  exit 1
}; fi

print_corruption_warning()
{
  cat << EOF
WARNING: Backup could not confirm that the database is valid. No files will be
copied to prevent overwriting the backup with corrupt data. To proceed, the
dispatcher and apply_osc_to_db.sh must be running. To perform a manual backup,
use rsync while the Overpass processes are stopped.
EOF
}

EXEC_DIR="$(realpath "$(dirname "$0")")"

DB_DIR=$("$EXEC_DIR/dispatcher" --show-dir) || { echo "ERROR: dispatcher --show-dir failed"; exit 1; }
DB_DIR="$(realpath "$DB_DIR")"

if ! [[ -d $DB_DIR && -w $DB_DIR ]]; then
  echo "ERROR: Database directory '$DB_DIR' is not a writeable directory"
  exit 1
fi

BACKUP_DIR="$1"
BACKUP_DIR="$(realpath "$BACKUP_DIR")"

if ! [[ -d $BACKUP_DIR && -w $BACKUP_DIR ]]; then
  echo "ERROR: Backup directory '$BACKUP_DIR' is not a writeable directory"
  exit 1
fi

APPLY_OSC_PID=$(cat "$DB_DIR/apply_osc_to_db.pid") 2>/dev/null
if [[ -z "$APPLY_OSC_PID" ]]; then
  echo "ERROR: apply_osc_to_db.pid is missing or empty"
  print_corruption_warning
  exit 1
fi
if ! kill -0 "$APPLY_OSC_PID" 2>/dev/null; then
  echo "ERROR: apply_osc_to_db.sh is not running"
  print_corruption_warning
  exit 1
fi

if "$EXEC_DIR/dispatcher" --areas --show-dir > /dev/null 2>&1; then
  AREAS="yes"
else
  AREAS="no"
fi

# Log file
LOG_FILE="$DB_DIR/backup.log"

# Backup timeout (seconds)
BACKUP_TIMEOUT=${OVERPASS_BACKUP_TIMEOUT:-7200}      # 2 hours
BACKUP_TIME=${OVERPASS_BACKUP_TIME:-}
BACKUP_DAY=${OVERPASS_BACKUP_DAY:-}
BACKUP_DAY="${BACKUP_DAY^^}"

if [[ -n "$BACKUP_DAY" ]]; then
  if [[ ! "$BACKUP_DAY" =~ ^(MON|TUE|WED|THU|FRI|SAT|SUN)$ ]] && \
     [[ ! "$BACKUP_DAY" =~ ^([1-9]|[12][0-9]|3[01])$ ]]; then
    echo "ERROR: OVERPASS_BACKUP_DAY must be a day of week (MON-SUN) or day of month (1-31), got: '$OVERPASS_BACKUP_DAY'"
    exit 1
  fi
  if [[ -z "$BACKUP_TIME" ]]; then
    BACKUP_TIME="00:00"
  fi
fi

if [[ -n "$BACKUP_TIME" ]] && \
   [[ ! "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  echo "ERROR: OVERPASS_BACKUP_TIME must be in HH:MM format (00:00-23:59), got: '$OVERPASS_BACKUP_TIME'"
  exit 1
fi

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
# BACKUP FILES
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
base-url osm_base_version replicate_id"

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
# LOCK MANAGEMENT
# ============================================================================

acquire_lock()
{
  local type="$1"
  local lock_file
  if [[ "$type" == "base" ]]; then
    lock_file="$DB_DIR/osm_base_shadow.lock"
  elif [[ "$type" == "areas" ]]; then
    lock_file="$DB_DIR/areas_shadow.lock"
  else
    log_error "acquire_lock: unknown type '$type'"
    return 1
  fi

  log_message "Acquiring $type lock..."
  while true; do
    if ( set -o noclobber; echo "$$" > "$lock_file" ) 2>/dev/null; then
      local pid_in_file
      pid_in_file=$(cat "$lock_file" 2>/dev/null)
      [[ "$pid_in_file" == "$$" ]] && break
    fi
    sleep 0.5
  done
  log_message "$type lock acquired"
}

release_lock()
{
  local type="$1"
  local lock_file
  if [[ "$type" == "base" ]]; then
    lock_file="$DB_DIR/osm_base_shadow.lock"
  elif [[ "$type" == "areas" ]]; then
    lock_file="$DB_DIR/areas_shadow.lock"
  else
    log_error "release_lock: unknown type '$type'"
    return 1
  fi

  local pid_in_file
  pid_in_file=$(cat "$lock_file" 2>/dev/null)
  if [[ "$pid_in_file" != "$$" ]]; then
    log_error "release_lock: $type lock file contains unexpected PID '$pid_in_file', not removing"
    return 1
  fi
  rm -f "$lock_file" || { log_error "release_lock: failed to remove $type lock file '$lock_file'"; return 1; }
  log_message "$type lock released"
}

# ============================================================================
# SIGNAL HANDLING
# ============================================================================

shutdown()
{
  local EXIT_CODE=$1
  trap '' SIGTERM SIGINT SIGHUP
  for lock_file in "$DB_DIR/osm_base_shadow.lock" "$DB_DIR/areas_shadow.lock"; do
    local pid_in_file
    pid_in_file=$(cat "$lock_file" 2>/dev/null)
    if [[ "$pid_in_file" == "$$" ]]; then
      rm -f "$lock_file" || log_error "shutdown: failed to remove lock file '$lock_file'"
    fi
  done
  exit "$EXIT_CODE"
}

trap 'shutdown 143' SIGTERM
trap 'shutdown 130' SIGINT
trap 'shutdown 129' SIGHUP

# ============================================================================
# DATABASE STATE DETECTION
# ============================================================================

# Detect the meta mode of the database by checking for characteristic files
# Returns: "no", "yes", or "attic" via stdout
# Returns 1 if base files are missing (database not initialized)
detect_database_meta_state()
{
  # Check for attic files (most specific check first)
  if [[ -f "$DB_DIR/nodes_attic.bin" || -f "$DB_DIR/node_changelog.bin" || -f "$DB_DIR/ways_attic.bin" ]]; then
    echo "attic"
    return 0
  fi

  # Check for meta files
  if [[ -f "$DB_DIR/nodes_meta.bin" || -f "$DB_DIR/ways_meta.bin" || -f "$DB_DIR/user_data.bin" ]]; then
    echo "yes"
    return 0
  fi

  # No meta or attic files found - verify base files exist
  if [[ ! -f "$DB_DIR/nodes.bin" || ! -f "$DB_DIR/ways.bin" || ! -f "$DB_DIR/relations.bin" ]]; then
    return 1
  fi

  echo "no"
  return 0
}

# ============================================================================
# COPY FILES
# ============================================================================

copy_files()
{
  local exit_code
  # shellcheck disable=SC2068
  printf '%s\n' $@ \
    | timeout "$BACKUP_TIMEOUT" rsync -a --files-from=- "$DB_DIR/" "$BACKUP_DIR/"
  exit_code=$?
  if [[ $exit_code -eq 124 ]]; then
    log_error "rsync timed out after ${BACKUP_TIMEOUT}s"
    return 1
  elif [[ $exit_code -ne 0 ]]; then
    log_error "rsync failed (exit $exit_code)"
    return 1
  fi
}

# ============================================================================
# SLEEP
# ============================================================================

dow_number()
{
  case "$1" in
    MON) echo 1 ;; TUE) echo 2 ;; WED) echo 3 ;; THU) echo 4 ;;
    FRI) echo 5 ;; SAT) echo 6 ;; SUN) echo 7 ;;
  esac
}

is_backup_day()
{
  if [[ "$BACKUP_DAY" =~ ^[0-9]+$ ]]; then
    [[ $(date +%-d) -eq $BACKUP_DAY ]]
  else
    [[ $(date +%u) -eq $(dow_number "$BACKUP_DAY") ]]
  fi
}

calculate_sleep_time()
{
  local NOW
  NOW=$(date +%s)

  local NEXT_BACKUP
  NEXT_BACKUP=$(date -d "today $BACKUP_TIME" +%s)
  (( NEXT_BACKUP <= NOW )) && NEXT_BACKUP=$(date -d "tomorrow $BACKUP_TIME" +%s)

  local SLEEP_TIME=$(( NEXT_BACKUP - NOW ))
  if [[ $SLEEP_TIME -lt 1 ]]; then
    echo "1"
  else
    echo "$SLEEP_TIME"
  fi
}

sleep_with_interrupts() {
  sleep "$1" &
  wait $!
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

while true; do
{
  if [[ -n "$BACKUP_DAY" ]] && ! is_backup_day; then
    SLEEP_TIME=$(calculate_sleep_time)
    sleep_with_interrupts "$SLEEP_TIME"
    continue
  fi

  META_STATE=$(detect_database_meta_state) \
    || { log_error "Database not initialized (missing base files)"; exit 1; }

  log_message "Backup started (meta=$META_STATE, areas=$AREAS)"

  acquire_lock base || shutdown 1

  # shellcheck disable=SC2086
  copy_files $FILES_BASE || shutdown 1

  if [[ "$META_STATE" == "yes" || "$META_STATE" == "attic" ]]; then
    # shellcheck disable=SC2086
    copy_files $FILES_META || shutdown 1
  fi

  if [[ "$META_STATE" == "attic" ]]; then
    # shellcheck disable=SC2086
    copy_files $FILES_ATTIC || shutdown 1
  fi

  release_lock base || shutdown 1

  if [[ "$AREAS" == "yes" ]]; then
    acquire_lock areas || shutdown 1
    # shellcheck disable=SC2086
    copy_files $FILES_AREAS || shutdown 1
    release_lock areas || shutdown 1
  fi

  log_message "Backup complete"

  if [[ -z "$BACKUP_TIME" ]]; then
    break;
  else
    SLEEP_TIME=$(calculate_sleep_time)
    sleep_with_interrupts "$SLEEP_TIME"
  fi
}
done
