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
# Script: clean_osc.sh
# Purpose: Removes OSC files older than the current database state to
#          reclaim disk space while keeping files needed for apply process
# ============================================================================

usage()
{
  echo "Usage: $0 db_dir diff_dir keep_count"
  echo "       $0 --all diff_dir"
  echo ""
  echo "  db_dir:      Database directory (contains replicate_id file)"
  echo "  diff_dir:    Directory containing downloaded OSC files"
  echo "  keep_count:  Number of additional files to keep beyond database state"
  echo ""
  echo "  --all:       Delete ALL downloaded OSC files (for recovery scenarios)"
  echo ""
  echo "This script removes .osc.gz and .state.txt files older than the current"
  echo "database state minus keep_count, helping to reclaim disk space."
  echo ""
  echo "The --all flag is used for recovery scenarios where you want to delete"
  echo "all downloaded files and start fresh."
}

# ============================================================================
# CONFIGURATION
# ============================================================================

# Check for --all flag
if [[ "$1" == "--all" ]]; then
  ALL_MODE=true
  DB_DIR=""
  LOCAL_DIR="$2"
  KEEP_COUNT=0
else
  ALL_MODE=false
  DB_DIR="$1"
  LOCAL_DIR="$2"
  KEEP_COUNT="$3"
fi

# Validate DB_DIR (skip if in --all mode)
if [[ "$ALL_MODE" == "false" ]]; then
  if [[ -z "$DB_DIR" ]]; then
    echo "ERROR: Database directory parameter is required"
    usage
    exit 1
  fi

  if [[ ! -e "$DB_DIR" ]]; then
    echo "ERROR: Database directory '$DB_DIR' does not exist"
    exit 1
  fi

  if [[ ! -d "$DB_DIR" ]]; then
    echo "ERROR: '$DB_DIR' exists but is not a directory"
    exit 1
  fi

  if [[ ! -r "$DB_DIR" ]]; then
    echo "ERROR: Database directory '$DB_DIR' is not readable (check permissions)"
    exit 1
  fi

  DB_DIR="$(realpath "$DB_DIR")"

  # State file
  STATE_FILE="$DB_DIR/replicate_id"
fi

# Validate LOCAL_DIR
if [[ -z "$LOCAL_DIR" ]]; then
  echo "ERROR: Local directory parameter is required"
  usage
  exit 1
fi

if [[ ! -e "$LOCAL_DIR" ]]; then
  echo "ERROR: Local directory '$LOCAL_DIR' does not exist"
  exit 1
fi

if [[ ! -d "$LOCAL_DIR" ]]; then
  echo "ERROR: '$LOCAL_DIR' exists but is not a directory"
  exit 1
fi

if [[ ! -r "$LOCAL_DIR" ]]; then
  echo "ERROR: Local directory '$LOCAL_DIR' is not readable (check permissions)"
  exit 1
fi

if [[ ! -w "$LOCAL_DIR" ]]; then
  echo "ERROR: Local directory '$LOCAL_DIR' is not writable (check permissions)"
  exit 1
fi

LOCAL_DIR="$(realpath "$LOCAL_DIR")"

# Validate KEEP_COUNT
if [[ ! "$KEEP_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: keep_count must be a positive integer, got: '$KEEP_COUNT'"
  usage
  exit 1
fi

# ============================================================================
# LOGGING
# ============================================================================

log_message()
{
  echo "$(date -u '+%F %T'): $1"
}

log_error()
{
  echo "$(date -u '+%F %T'): ERROR: $1"
}

# ============================================================================
# STATE READING
# ============================================================================

read_current_state()
{
  local STATE_PATH="$STATE_FILE"

  if [[ ! -e "$STATE_PATH" ]]; then
    log_error "State file '$STATE_PATH' does not exist"
    echo "0"
    return 1
  fi

  if [[ ! -f "$STATE_PATH" ]]; then
    log_error "State file '$STATE_PATH' exists but is not a regular file"
    echo "0"
    return 1
  fi

  if [[ ! -r "$STATE_PATH" ]]; then
    log_error "State file '$STATE_PATH' is not readable (check permissions)"
    echo "0"
    return 1
  fi

  if [[ ! -s "$STATE_PATH" ]]; then
    log_error "State file '$STATE_PATH' is empty"
    echo "0"
    return 1
  fi

  local STATE_VALUE
  STATE_VALUE=$(cat "$STATE_PATH" 2>/dev/null)

  if [[ -z "$STATE_VALUE" ]]; then
    log_error "Failed to read state file '$STATE_PATH'"
    echo "0"
    return 1
  fi

  # Validate that it's a number
  if ! [[ "$STATE_VALUE" =~ ^[0-9]+$ ]]; then
    log_error "State file '$STATE_PATH' contains invalid data: '$STATE_VALUE'"
    echo "0"
    return 1
  fi

  echo "$STATE_VALUE"
  return 0
}

# ============================================================================
# CLEANUP LOGIC
# ============================================================================

cleanup_all_files()
{
  log_message "Deleting ALL OSC files (recovery mode)"

  local CLEANED_FILES=0
  local CLEANED_DIRS=0

  # Find all OSC and state files
  for FILE in "$LOCAL_DIR"/[0-9][0-9][0-9]/[0-9][0-9][0-9]/[0-9][0-9][0-9].{osc.gz,state.txt}; do
    if [[ -f "$FILE" ]]; then
      rm -f "$FILE"
      (( ++CLEANED_FILES ))
    fi
  done

  # Remove all numbered directories
  for DIR1 in "$LOCAL_DIR"/[0-9][0-9][0-9]; do
    if [[ -d "$DIR1" ]]; then
      rm -rf "$DIR1"
      (( ++CLEANED_DIRS ))
    fi
  done

  # Also remove state.txt and replicate_id if present in LOCAL_DIR
  rm -f "$LOCAL_DIR/state.txt" "$LOCAL_DIR/replicate_id"

  log_message "Deleted $CLEANED_FILES files and removed $CLEANED_DIRS directories"

  return 0
}

cleanup_old_files()
{
  local CURRENT_STATE="$1"
  local CLEANUP_THRESHOLD
  CLEANUP_THRESHOLD=$(( CURRENT_STATE - KEEP_COUNT ))

  if [[ $CLEANUP_THRESHOLD -le 0 ]]; then
    log_message "Cleanup threshold is $CLEANUP_THRESHOLD, nothing to clean"
    return 0
  fi

  log_message "Cleaning OSC files older than $CLEANUP_THRESHOLD (current state: $CURRENT_STATE, keeping $KEEP_COUNT extra)"

  local CLEANED_FILES=0
  local CLEANED_DIRS=0

  # Calculate threshold path components
  printf -v THRESHOLD_DIGIT3 '%03u' $(( CLEANUP_THRESHOLD % 1000 ))
  local ARG=$(( CLEANUP_THRESHOLD / 1000 ))
  printf -v THRESHOLD_DIGIT2 '%03u' $(( ARG % 1000 ))
  ARG=$(( ARG / 1000 ))
  printf -v THRESHOLD_DIGIT1 '%03u' "$ARG"

  log_message "Threshold path: $THRESHOLD_DIGIT1/$THRESHOLD_DIGIT2/$THRESHOLD_DIGIT3"

  # Find all top-level directories (000-999)
  for DIR1 in "$LOCAL_DIR"/[0-9][0-9][0-9]; do
    if [[ ! -d "$DIR1" ]]; then
      continue
    fi

    local DIGIT1
    DIGIT1=$(basename "$DIR1")

    # Skip if this top-level directory is beyond our threshold
    if [[ $DIGIT1 -gt $THRESHOLD_DIGIT1 ]]; then
      continue
    fi

    # Find all second-level directories (000-999)
    for DIR2 in "$DIR1"/[0-9][0-9][0-9]; do
      if [[ ! -d "$DIR2" ]]; then
        continue
      fi

      local DIGIT2
      DIGIT2=$(basename "$DIR2")

      # Skip if this directory path is beyond our threshold
      if [[ $DIGIT1 -eq $THRESHOLD_DIGIT1 && $DIGIT2 -gt $THRESHOLD_DIGIT2 ]]; then
        continue
      fi

      # Process all files in this directory
      for FILE in "$DIR2"/[0-9][0-9][0-9].{osc.gz,state.txt}; do
        if [[ ! -f "$FILE" ]]; then
          continue
        fi

        local FILENAME
        FILENAME=$(basename "$FILE")
        local DIGIT3="${FILENAME:0:3}"

        # Calculate the full ID
        local FILE_ID=$(( 10#$DIGIT1 * 1000000 + 10#$DIGIT2 * 1000 + 10#$DIGIT3 ))

        # Delete if older than threshold
        if [[ $FILE_ID -le $CLEANUP_THRESHOLD ]]; then
          rm -f "$FILE"
          (( ++CLEANED_FILES ))
        fi
      done

      # Remove directory if now empty
      if rmdir "$DIR2" 2>/dev/null; then
        (( ++CLEANED_DIRS ))
      fi
    done

    # Remove directory if now empty
    if rmdir "$DIR1" 2>/dev/null; then
      (( ++CLEANED_DIRS ))
    fi
  done

  if [[ $CLEANED_FILES -gt 0 ]]; then
    log_message "Cleaned up $CLEANED_FILES files and removed $CLEANED_DIRS empty directories"
  else
    log_message "No files needed cleaning"
  fi

  return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

if [[ "$ALL_MODE" == "true" ]]; then
  log_message "=========================================="
  log_message "Starting cleanup process (ALL MODE)"
  log_message "Local directory: $LOCAL_DIR"
  log_message "=========================================="

  cleanup_all_files

  log_message "Cleanup complete"
  log_message "=========================================="
  exit 0
fi

# Normal mode - clean based on database state
log_message "=========================================="
log_message "Starting cleanup process"
log_message "Database directory: $DB_DIR"
log_message "Local directory: $LOCAL_DIR"
log_message "Keep count: $KEEP_COUNT"
log_message "=========================================="

CURRENT_STATE=$(read_current_state)
READ_EXIT=$?

if [[ $READ_EXIT -ne 0 ]]; then
  log_error "Failed to read current database state"
  exit 1
fi

if [[ $CURRENT_STATE -eq 0 ]]; then
  log_error "Database state is 0, cannot determine what to clean"
  exit 1
fi

log_message "Current database state: $CURRENT_STATE"

cleanup_old_files "$CURRENT_STATE"

log_message "Cleanup complete"
log_message "=========================================="
