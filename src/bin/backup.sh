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
# Robust backup script for Overpass API
# Performs safe backup with process verification and error handling
# ============================================================================

usage()
{
  cat << EOF
Usage: $0 [--time HH:MM] [--day DAY] backup_dir

  backup_dir        Target directory for backup files
  --time HH:MM      Time of day to run backup (00:00-23:59); if omitted, runs once immediately
  --day DAY         Day to run backup: MON|TUE|WED|THU|FRI|SAT|SUN or 1-31
                    implies --time 00:00 if --time is not specified

Environment variables (overridden by arguments):
  OVERPASS_BACKUP_TIME        Same as --time
  OVERPASS_BACKUP_DAY         Same as --day
  OVERPASS_BACKUP_TIMEOUT     Rsync timeout in seconds (default: 7200)
  OVERPASS_UPDATE_FREQUENCY   Update interval in seconds; used to tickle replicate_id
                              while the lock is held (default: 60)
  OVERPASS_MIN_FREE_DISK_PERCENT
                              Headroom added to the estimated space needed for backup,
                              as a percentage; backup is skipped if not met (default: 5)
EOF
}

ARGS=$(getopt -o '' --long 'time:,day:' -n "$0" -- "$@") || { usage; exit 1; }
eval set -- "$ARGS"

ARG_TIME=""
ARG_DAY=""
while true; do
  case "$1" in
    --time) ARG_TIME="$2"; shift 2 ;;
    --day)  ARG_DAY="$2";  shift 2 ;;
    --) shift; break ;;
  esac
done

if [[ -z "${1:-}" ]]; then
  usage
  exit 1
fi

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

BACKUP_DIR="$(realpath "$1")"

mkdir -p "$BACKUP_DIR" || { echo "ERROR: Unable to acccess backup directory '$BACKUP_DIR'"; exit 1; }
if [[ ! -w $BACKUP_DIR ]]; then
  echo "ERROR: Backup directory '$BACKUP_DIR' is not writeable"
  exit 1
fi

APPLY_OSC_PID=$(cat "$DB_DIR/apply_osc.pid") 2>/dev/null
if [[ -z "$APPLY_OSC_PID" ]]; then
  echo "ERROR: apply_osc.pid is missing or empty"
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
UPDATE_FREQUENCY=${OVERPASS_UPDATE_FREQUENCY:-60}
MIN_FREE_DISK_PERCENT=${OVERPASS_MIN_FREE_DISK_PERCENT:-5}
BACKUP_TIME=${ARG_TIME:-${OVERPASS_BACKUP_TIME:-}}
BACKUP_DAY=${ARG_DAY:-${OVERPASS_BACKUP_DAY:-}}
BACKUP_DAY="${BACKUP_DAY^^}"

if [[ -n "$BACKUP_DAY" ]]; then
  if [[ ! "$BACKUP_DAY" =~ ^(MON|TUE|WED|THU|FRI|SAT|SUN)$ ]] && \
     [[ ! "$BACKUP_DAY" =~ ^([1-9]|[12][0-9]|3[01])$ ]]; then
    echo "ERROR: --day / OVERPASS_BACKUP_DAY must be a day of week (MON-SUN) or day of month (1-31), got: '$BACKUP_DAY'"
    exit 1
  fi
  if [[ -z "$BACKUP_TIME" ]]; then
    BACKUP_TIME="00:00"
  fi
fi

if (( BACKUP_DAY > 28 )); then
  echo "WARNING: --day / OVERPASS_BACKUP_DAY set to $BACKUP_DAY will result in erratic backup frequency"
fi

if [[ -n "$BACKUP_TIME" ]] && \
   [[ ! "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  echo "ERROR: --time / OVERPASS_BACKUP_TIME must be in HH:MM format (00:00-23:59), got: '$BACKUP_TIME'"
  exit 1
fi

if [[ ! "$UPDATE_FREQUENCY" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: OVERPASS_UPDATE_FREQUENCY must be a positive integer, got: '$UPDATE_FREQUENCY'"
  exit 1
fi

if [[ ! "$MIN_FREE_DISK_PERCENT" =~ ^[0-9]+$ || $MIN_FREE_DISK_PERCENT -ge 100 ]]; then
  echo "ERROR: OVERPASS_MIN_FREE_DISK_PERCENT must be an integer from 0 to 99 (got: $MIN_FREE_DISK_PERCENT)"
  exit 1
fi

if [[ -n "$BACKUP_TIME" ]]; then
  DATE_CHECK=$(date -d "today $BACKUP_TIME" +%s 2>/dev/null)
  if [[ "$?" -ne 0 || ! "$DATE_CHECK" =~ ^[0-9]+$ ]]; then
    echo "ERROR: The 'date' command on this system cannot parse relative date expressions (e.g., 'today 03:00')."
    echo "Update your system packages, install GNU date, or use the Docker container instead."
    exit 1
  fi
fi

if [[ "$BACKUP_DAY" =~ ^[0-9]+$ ]]; then
  DATE_CHECK=$(date +%-d 2>/dev/null)
  if [[ "$?" -ne 0 || ! "$DATE_CHECK" =~ ^[0-9]+$ ]]; then
    echo "ERROR: The 'date' command on this system does not support the '%-d' format specifier."
    echo "Update your system packages, install GNU date, or use the Docker container instead."
    exit 1
  fi
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
  log_message "Acquired $type lock"
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
  log_message "Released $type lock"
}

# ============================================================================
# SIGNAL HANDLING
# ============================================================================

RSYNC_PID=

stop_rsync()
{
  if [[ -n "$RSYNC_PID" ]]; then
    kill "$RSYNC_PID" 2>/dev/null || true
    wait "$RSYNC_PID" 2>/dev/null || true
    RSYNC_PID=
  fi
}

shutdown()
{
  local EXIT_CODE=$1
  trap '' SIGTERM SIGINT SIGHUP
  stop_rsync
  stop_tickle
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
# TICKLE REPLICATE_ID
# ============================================================================

# run_osm3s.sh monitors the mtime of replicate_id to detect a stalled update
# process: if the file has not been updated within STALL_THRESHOLD seconds
# (default 300s), it assumes that apply_osc_to_db.sh has hung and shuts down.
#
# While backup.sh holds the base lock, apply_osc_to_db.sh cannot complete an
# update cycle, so replicate_id will not be updated. If the backup takes longer
# than STALL_THRESHOLD, run_osm3s.sh will incorrectly trigger a shutdown.
#
# The fix: while we hold the base lock, periodically touch replicate_id (without
# changing its contents) to update its mtime. This tells run_osm3s.sh that the
# database is still being actively managed, even though no updates are being
# applied.

TICKLE_PID=

tickle_replicate_id()
{
  while true; do
    sleep_with_interrupts "$UPDATE_FREQUENCY"
    touch "$DB_DIR/replicate_id" 2>/dev/null || true
  done
}

stop_tickle()
{
  if [[ -n "$TICKLE_PID" ]]; then
    kill "$TICKLE_PID" 2>/dev/null || true
    wait "$TICKLE_PID" 2>/dev/null || true
    TICKLE_PID=
  fi
}

# ============================================================================
# COPY FILES
# ============================================================================

copy_files()
{
  local exit_code
  local files=()
  local f
  for f in "$@"; do
    files+=("$DB_DIR/$f")
  done
  timeout "$BACKUP_TIMEOUT" rsync -a --ignore-missing-args "${files[@]}" "$BACKUP_DIR/" &
  RSYNC_PID=$!
  wait "$RSYNC_PID"
  exit_code=$?
  RSYNC_PID=
  if [[ $exit_code -eq 124 ]]; then
    log_error "rsync timed out after ${BACKUP_TIMEOUT}s"
    return 1
  elif [[ $exit_code -ne 0 ]]; then
    log_error "rsync failed (exit $exit_code)"
    return 1
  fi
}

# ============================================================================
# DISK SPACE CHECK
# ============================================================================

check_backup_disk_space()
{
  local DB_SIZE BACKUP_SIZE LARGEST_FILE DELTA THRESHOLD FREE_BYTES

  DB_SIZE=$(du -sb "$DB_DIR" | cut -f1)
  BACKUP_SIZE=$(du -sb "$BACKUP_DIR" | cut -f1)
  LARGEST_FILE=$(find "$DB_DIR" -maxdepth 1 -type f -printf '%s\n' 2>/dev/null | sort -n | tail -1)
  LARGEST_FILE=${LARGEST_FILE:-0}

  DELTA=$(( DB_SIZE - BACKUP_SIZE ))
  (( DELTA < 0 )) && DELTA=0

  THRESHOLD=$(( (DELTA + LARGEST_FILE) * (100 + MIN_FREE_DISK_PERCENT) / 100 ))

  FREE_BYTES=$(df --output=avail -B1 "$BACKUP_DIR" | tail -1 | tr -d ' ')

  if [[ $FREE_BYTES -lt $THRESHOLD ]]; then
    log_error "Insufficient free disk space on backup filesystem: ${FREE_BYTES} bytes free (minimum: ${THRESHOLD} bytes)"
    return 1
  fi
  return 0
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
# STARTUP
# ============================================================================

log_message "-----------------------------------"
log_message "Starting backup.sh"
log_message "-----------------------------------"
log_message "BACKUP_DIR                         $BACKUP_DIR"
log_message "BACKUP_TIME                        ${BACKUP_TIME:-(not set, one-shot mode)}"
log_message "BACKUP_DAY                         ${BACKUP_DAY:-(not set)}"
log_message "BACKUP_TIMEOUT                     $BACKUP_TIMEOUT seconds"
log_message "UPDATE_FREQUENCY                   $UPDATE_FREQUENCY seconds"
log_message "OVERPASS_MIN_FREE_DISK_PERCENT     $MIN_FREE_DISK_PERCENT"
log_message "-----------------------------------"

# ============================================================================
# MAIN EXECUTION
# ============================================================================

while true; do
{
  if [[ -n "$BACKUP_TIME" ]]; then
    SLEEP_TIME=$(calculate_sleep_time)
    sleep_with_interrupts "$SLEEP_TIME"
  fi

  if [[ -n "$BACKUP_DAY" ]] && ! is_backup_day; then
    continue
  fi

  META_STATE=$(detect_database_meta_state) \
    || { log_error "Database not initialized (missing base files)"; exit 1; }

  if ! check_backup_disk_space; then
    exit 1
  fi

  log_message "Backup started (meta=$META_STATE, areas=$AREAS)"

  acquire_lock base || shutdown 1
  tickle_replicate_id &
  TICKLE_PID=$!

  log_message "Backing up base files"
  # shellcheck disable=SC2086
  copy_files $FILES_BASE || shutdown 1

  if [[ "$META_STATE" == "yes" || "$META_STATE" == "attic" ]]; then
    log_message "Backing up meta files"
    # shellcheck disable=SC2086
    copy_files $FILES_META || shutdown 1
  fi

  if [[ "$META_STATE" == "attic" ]]; then
    log_message "Backing up attic files"
    # shellcheck disable=SC2086
    copy_files $FILES_ATTIC || shutdown 1
  fi

  stop_tickle
  release_lock base || shutdown 1

  if [[ "$AREAS" == "yes" ]]; then
    acquire_lock areas || shutdown 1
    log_message "Backing up area files"
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
