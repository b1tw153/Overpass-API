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

EXEC_DIR="$(realpath "$(dirname "$0")")"

if [[ -n "$1" ]]; then
  DB_DIR="$1"
else
  DB_DIR=$("$EXEC_DIR"/dispatcher --show-dir) || { echo "ERROR: dispatcher --show-dir failed"; exit 1; }
fi

if [[ -z "$DB_DIR" ]]; then
  echo "ERROR: could not determine database directory"
  echo "Usage: $0 db-dir"
  exit 1
fi

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
  exit 1
fi

POLL_INTERVAL=$(( OVERPASS_UPDATE_FREQUENCY / 60 ))
(( POLL_INTERVAL < 1 )) && POLL_INTERVAL=1

LOG_FILE="$DB_DIR/rules_loop.log"

log_message() {
  echo "$(date -u '+%F %T'): $1" >> "$LOG_FILE"
}

calculate_sleep_time() {
  local NOW
  NOW=$(date +%s)
  local SLEEP_TIME=$(( LAST_UPDATE_TIME + OVERPASS_UPDATE_FREQUENCY - NOW ))
  if [[ $SLEEP_TIME -lt 1 ]]; then
    echo "$POLL_INTERVAL"
  else
    echo "$SLEEP_TIME"
  fi
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
LAST_UPDATE_TIME=""

while true; do
  CURRENT_REPLICATE_ID=$(cat "$DB_DIR/replicate_id" 2>/dev/null)

  if [[ "$CURRENT_REPLICATE_ID" != "$LAST_REPLICATE_ID" ]]; then
    LAST_UPDATE_TIME=$(stat -c %Y "$DB_DIR/replicate_id" 2>/dev/null)
    log_message "Area update started"
    "$EXEC_DIR/osm3s_query" --progress --rules < "$DB_DIR/rules/areas.osm3s" &
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
  fi

  SLEEP_TIME=$(calculate_sleep_time)
  sleep_with_interrupts "$SLEEP_TIME"
done
