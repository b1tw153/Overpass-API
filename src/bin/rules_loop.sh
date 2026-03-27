#!/usr/bin/env bash

# Copyright 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018 Roland Olbricht et al.
#
# This file is part of Overpass_API.
# With improvements in 2026 by Kai Johnson
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

usage()
{
  cat << EOF
Usage: $0 [db_dir]

  db_dir   (Optional, deprecated) Database directory; ignored if provided

Environment variables:
  OVERPASS_UPDATE_FREQUENCY   Update interval in seconds (default: 60)
  AREA_UPDATE_TIME            Time of day to run area updates in HH:MM format;
                              if unset, updates run on every database change
  AREA_RULES_FILE             Path to the area rules file
                              (default: <database directory>/rules/areas.osm3s)
EOF
}

if [[ -n "$1" ]]; then
  echo "INFO: The DB_DIR argument is deprecated and is no longer used"
  usage
fi

EXEC_DIR="$(realpath "$(dirname "$0")")"

DB_DIR=$("$EXEC_DIR"/dispatcher --show-dir) || { echo "ERROR: dispatcher --show-dir failed"; exit 1; }
if ! [[ -d $DB_DIR && -w $DB_DIR ]]; then
  echo "ERROR: Database directory '$DB_DIR' is not a writeable directory"
  exit 1
fi

DB_DIR="$(realpath "$DB_DIR")"

if [[ ! -f "$DB_DIR/nodes.bin" || ! -f "$DB_DIR/ways.bin" || ! -f "$DB_DIR/relations.bin" ]]; then
  echo "ERROR: Database is not initialized (missing nodes.bin, ways.bin, or relations.bin)"
  exit 1
fi

OVERPASS_UPDATE_FREQUENCY="${OVERPASS_UPDATE_FREQUENCY:-60}"

if [[ ! "$OVERPASS_UPDATE_FREQUENCY" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: OVERPASS_UPDATE_FREQUENCY must be a positive integer, got: '$OVERPASS_UPDATE_FREQUENCY'"
  usage
  exit 1
fi

POLL_INTERVAL=$(( OVERPASS_UPDATE_FREQUENCY / 60 ))
(( POLL_INTERVAL < 1 )) && POLL_INTERVAL=1

AREA_RULES_FILE="${AREA_RULES_FILE:-$DB_DIR/rules/areas.osm3s}"

if [[ ! -f "$AREA_RULES_FILE" ]]; then
  echo "ERROR: Rules file not found: '$AREA_RULES_FILE'"
  usage
  exit 1
fi

AREA_UPDATE_TIME="${AREA_UPDATE_TIME:-}"

if [[ -n "$AREA_UPDATE_TIME" ]] && \
   [[ ! "$AREA_UPDATE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  echo "ERROR: AREA_UPDATE_TIME must be in HH:MM format (00:00-23:59), got: '$AREA_UPDATE_TIME'"
  usage
  exit 1
fi

if [[ -n "$AREA_UPDATE_TIME" ]]; then
  DATE_CHECK=$(date -d "today $AREA_UPDATE_TIME" +%s 2>/dev/null)
  if [[ "$?" -ne 0 || ! "$DATE_CHECK" =~ ^[0-9]+$ ]]; then
    echo "ERROR: The 'date' command on this system cannot parse relative date expressions (e.g., 'today 03:00')."
    echo "Update your system packages, install GNU date, or use the Docker container instead."
    exit 1
  fi
fi

LOG_FILE="$DB_DIR/rules_loop.log"

log_message() {
  echo "$(date -u '+%F %T'): $1" >> "$LOG_FILE"
}

calculate_sleep_time() {
  local NOW
  NOW=$(date +%s)
  local SLEEP_TIME=$(( LAST_DB_UPDATE_TIME + OVERPASS_UPDATE_FREQUENCY - NOW ))
  if [[ -n "$AREA_UPDATE_TIME" ]]; then
    local AREA_SLEEP=$(( NEXT_AREA_UPDATE_TIME - NOW ))
    if (( AREA_SLEEP > 0 && AREA_SLEEP < SLEEP_TIME )); then
      SLEEP_TIME=$AREA_SLEEP
    fi
  fi
  if [[ $SLEEP_TIME -lt 1 ]]; then
    echo "$POLL_INTERVAL"
  else
    echo "$SLEEP_TIME"
  fi
}

compute_next_area_update_time() {
  if [[ -z "$AREA_UPDATE_TIME" ]]; then
    NEXT_AREA_UPDATE_TIME=0
    return
  fi

  NEXT_AREA_UPDATE_TIME=$(date -d "today $AREA_UPDATE_TIME" +%s)
  (( NEXT_AREA_UPDATE_TIME < $(date +%s) )) && NEXT_AREA_UPDATE_TIME=$(date -d "tomorrow $AREA_UPDATE_TIME" +%s)
}

should_update_areas() {
  [[ -z "$AREA_UPDATE_TIME" ]] && return 0
  local NOW
  NOW=$(date +%s)
  (( NOW >= NEXT_AREA_UPDATE_TIME ))
}

sleep_with_interrupts() {
  sleep "$1" &
  wait $!
}

QUERY_PID=""

shutdown() {
  local EXIT_CODE=$1
  [[ -n "$QUERY_PID" ]] && kill "$QUERY_PID" 2>/dev/null
  exit "$EXIT_CODE"
}

trap 'shutdown 143' SIGTERM
trap 'shutdown 130' SIGINT
trap 'shutdown 129' SIGHUP

LAST_REPLICATE_ID="none"
LAST_DB_UPDATE_TIME=""
NEXT_AREA_UPDATE_TIME=0

if [[ -n "$AREA_UPDATE_TIME" ]]; then
  compute_next_area_update_time
fi

while true; do
  CURRENT_REPLICATE_ID=$(cat "$DB_DIR/replicate_id" 2>/dev/null)

  if [[ "$CURRENT_REPLICATE_ID" != "$LAST_REPLICATE_ID" ]] && should_update_areas; then
    LAST_DB_UPDATE_TIME=$(stat -c %Y "$DB_DIR/replicate_id" 2>/dev/null)
    log_message "Area update started"
    "$EXEC_DIR/osm3s_query" --progress --rules < "$AREA_RULES_FILE" &
    QUERY_PID=$!
    wait "$QUERY_PID"
    QUERY_EXIT=$?
    QUERY_PID=""
    if [[ $QUERY_EXIT -ne 0 ]]; then
      log_message "Area update failed (osm3s_query exit code $QUERY_EXIT)"
    else
      log_message "Area update finished"
    fi
    LAST_REPLICATE_ID="$CURRENT_REPLICATE_ID"
    compute_next_area_update_time
  fi

  SLEEP_TIME=$(calculate_sleep_time)
  sleep_with_interrupts "$SLEEP_TIME"
done
