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
# Script: container-status.sh
# Purpose: Reports on the operational status of the Overpass API container.
#          Outputs plain text. Designed to be served via nginx at
#          /container-status using fcgiwrap.
# ============================================================================

set -euo pipefail

EXEC_DIR="$(realpath "$(dirname "$0")")"

# CGI header (omit when running interactively)
[[ -t 1 ]] || printf 'Content-Type: text/plain\r\n\r\n'

printf 'Status report: %s UTC\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"

# ============================================================================
# HELPERS
# ============================================================================

SEPARATOR="-----------------------------------"

section() {
    printf '\n%s\n%s\n%s\n' "$SEPARATOR" "$1" "$SEPARATOR"
}

kv() {
    printf '%-35s %s\n' "$1" "$2"
}

pid_status() {
    local pid="$1"
    if [[ -z "$pid" ]]; then
        echo "not running"
    elif kill -0 "$pid" 2>/dev/null; then
        echo "running (pid $pid)"
    else
        echo "dead (stale pid $pid)"
    fi
}

read_log() {
    cat "$1.1" "$1" 2>/dev/null || true
}

find_proc_pid() {
    local pattern="$1"
    local pid
    for cmdline_file in /proc/[0-9]*/cmdline; do
        [[ -r "$cmdline_file" ]] || continue
        pid="${cmdline_file%/cmdline}"
        pid="${pid##*proc/}"
        [[ "$pid" == "$$" ]] && continue
        if tr '\0' '\n' < "$cmdline_file" 2>/dev/null | grep -qF "$pattern"; then
            echo "$pid"
            return
        fi
    done
}

find_all_proc_pids() {
    local pattern="$1"
    local pid
    for cmdline_file in /proc/[0-9]*/cmdline; do
        [[ -r "$cmdline_file" ]] || continue
        pid="${cmdline_file%/cmdline}"
        pid="${pid##*proc/}"
        [[ "$pid" == "$$" ]] && continue
        if tr '\0' '\n' < "$cmdline_file" 2>/dev/null | grep -qF "$pattern"; then
            echo "$pid"
        fi
    done
}

proc_stats() {
    local pid="$1"
    local clk_tck=100
    local stat status_file
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return
    status_file=$(cat "/proc/$pid/status" 2>/dev/null) || return

    local utime stime starttime
    utime=$(echo "$stat" | awk '{print $14}')
    stime=$(echo "$stat" | awk '{print $15}')
    starttime=$(echo "$stat" | awk '{print $22}')

    local cpu_secs=$(( (utime + stime) / clk_tck ))
    local cpu_fmt
    cpu_fmt=$(printf '%02d:%02d:%02d' $(( cpu_secs/3600 )) $(( (cpu_secs%3600)/60 )) $(( cpu_secs%60 )))

    local uptime_secs
    uptime_secs=$(awk '{print int($1)}' /proc/uptime)
    local start_epoch=$(( $(date +%s) - uptime_secs + starttime / clk_tck ))
    local start_time
    start_time=$(date -d "@$start_epoch" -u '+%Y-%m-%d %H:%M:%S')

    local rss_kb
    rss_kb=$(echo "$status_file" | awk '/^VmRSS:/ {print $2}')
    local rss_mb=$(( rss_kb / 1024 ))

    printf 'pid %-8s  started %s  cpu %s  rss %dM\n' "$pid" "$start_time" "$cpu_fmt" "$rss_mb"
}

# ============================================================================
# NGINX / FCGIWRAP
# ============================================================================

section "nginx / fcgiwrap"

NGINX_PID_FILE=/opt/overpass/run/nginx.pid
FCGI_PID_FILE=/opt/overpass/run/fcgiwrap.pid
FCGI_SOCKET=/opt/overpass/run/fcgiwrap.socket
ACCESS_LOG=/opt/overpass/log/nginx_access.log

NGINX_PID=$(cat "$NGINX_PID_FILE" 2>/dev/null || true)
kv "nginx" "$(pid_status "$NGINX_PID")"

FCGI_PID=$(cat "$FCGI_PID_FILE" 2>/dev/null || true)
kv "fcgiwrap" "$(pid_status "$FCGI_PID")"

if [[ -S "$FCGI_SOCKET" ]]; then
    kv "socket" "present"
else
    kv "socket" "missing"
fi

NGINX_STATUS=$(curl -sf http://127.0.0.1:8080/nginx-status 2>/dev/null || true)
if [[ -n "$NGINX_STATUS" ]]; then
    kv "active connections" "$(echo "$NGINX_STATUS" | awk '/^Active/ {print $3}')"
    kv "in progress" "$(echo "$NGINX_STATUS" | awk '/Reading/ {print $4}')"
    kv "waiting (keep-alive)" "$(echo "$NGINX_STATUS" | awk '/Reading/ {print $6}')"
else
    kv "connections" "unavailable"
fi

if [[ -f "$ACCESS_LOG" ]]; then
    kv "requests" "$(awk '
        NF >= 9 {
            total++
            if (total == 1) first = $4
            last = $4
        }
        END {
            if (total == 0) {
                print "0"
            } else {
                gsub(/^\[/, "", first)
                gsub(/^\[/, "", last)
                printf "%d  (%s to %s)\n", total, first, last
            }
        }
    ' "$ACCESS_LOG")"
    awk '
        NF >= 9 { counts[$9]++ }
        END {
            for (code in counts)
                printf "%-35s %d\n", "  HTTP " code, counts[code]
        }
    ' "$ACCESS_LOG" | sort
else
    kv "access log" "not found"
fi

# ============================================================================
# BASE DISPATCHER / DATABASE
# ============================================================================

section "Base Dispatcher"

lock_status() {
    local lock_file="$1"
    if [[ ! -f "$lock_file" ]]; then
        echo "free"
        return
    fi
    local pid
    pid=$(cat "$lock_file" 2>/dev/null || true)
    if [[ -z "$pid" ]]; then
        echo "unknown (empty lock file)"
    elif kill -0 "$pid" 2>/dev/null; then
        echo "held by pid $pid"
    else
        echo "stale (pid $pid not running)"
    fi
}

DB_DIR=""
if DISPATCHER_OUTPUT=$("$EXEC_DIR/dispatcher" --show-dir 2>&1); then
    DB_DIR="$(realpath "$DISPATCHER_OUTPUT")"
    kv "status" "running"
    kv "db_dir" "$DB_DIR"
else
    kv "status" "not running"
fi

if [[ -n "$DB_DIR" ]]; then
    kv "osm_base lock" "$(lock_status "$DB_DIR/osm_base_shadow.lock")"
    kv "areas lock" "$(lock_status "$DB_DIR/areas_shadow.lock")"

    if [[ -f "$DB_DIR/nodes_attic.bin" || -f "$DB_DIR/node_changelog.bin" || -f "$DB_DIR/ways_attic.bin" ]]; then
        kv "database type" "attic"
    elif [[ -f "$DB_DIR/nodes_meta.bin" || -f "$DB_DIR/ways_meta.bin" || -f "$DB_DIR/user_data.bin" ]]; then
        kv "database type" "meta"
    elif [[ -f "$DB_DIR/nodes.bin" ]]; then
        kv "database type" "base"
    else
        kv "database type" "unknown (not initialized?)"
    fi

    REPLICATE_ID=$(cat "$DB_DIR/replicate_id" 2>/dev/null || true)
    kv "replicate_id" "${REPLICATE_ID:-unknown}"
fi

# ============================================================================
# AREAS DISPATCHER
# ============================================================================

section "Areas Dispatcher"

if "$EXEC_DIR/dispatcher" --areas --show-dir > /dev/null 2>&1; then
    kv "status" "running"
else
    kv "status" "not running"
fi

if [[ -n "$DB_DIR" ]]; then
    area_files=(
        areas.bin areas.bin.idx
        area_blocks.bin area_blocks.bin.idx
        area_tags_global.bin area_tags_global.bin.idx
        area_tags_local.bin area_tags_local.bin.idx
        area_version
    )
    area_present=0
    area_total=${#area_files[@]}
    for f in "${area_files[@]}"; do
        [[ -f "$DB_DIR/$f" ]] && (( area_present++ )) || true
    done
    AREA_VERSION=$(cat "$DB_DIR/area_version" 2>/dev/null || true)
    if (( area_present == area_total )); then
        kv "area files" "present ($area_present/$area_total)"
    elif (( area_present == 0 )); then
        kv "area files" "missing"
    else
        kv "area files" "partial ($area_present/$area_total)"
    fi
    [[ -n "$AREA_VERSION" ]] && kv "area version" "$AREA_VERSION" || true
fi

# ============================================================================
# APPLY_OSC_TO_DB
# ============================================================================

section "apply_osc_to_db.sh"

if [[ -n "$DB_DIR" ]]; then
    APPLY_PID=$(cat "$DB_DIR/apply_osc.pid" 2>/dev/null || true)
    kv "status" "$(pid_status "$APPLY_PID")"

    APPLY_LOG="$DB_DIR/apply_osc_to_db.log"
    if [[ -f "$APPLY_LOG" ]]; then
        LAST_APPLY=$(read_log "$APPLY_LOG" | grep "Successfully applied batch up to" | tail -1 || true)
        if [[ -n "$LAST_APPLY" ]]; then
            LAST_APPLY_TIME=$(echo "$LAST_APPLY" | awk '{print $1, substr($2, 1, length($2)-1)}')
            LAST_APPLY_ID=$(echo "$LAST_APPLY" | grep -o '[0-9]*$')
            kv "last update" "$LAST_APPLY_TIME"
            kv "last replicate_id" "$LAST_APPLY_ID"
        else
            kv "last update" "not found in log"
        fi

        NEXT_BATCH=$(read_log "$APPLY_LOG" | grep "Next batch expected" | tail -1 || true)
        if [[ -n "$NEXT_BATCH" ]]; then
            NEXT_BATCH_TIME=$(echo "$NEXT_BATCH" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}' | tail -1)
            kv "next update" "$NEXT_BATCH_TIME"
        fi

        PHASE_LINE=$(read_log "$APPLY_LOG" | grep -E "Successfully applied batch|Applying batch to database|Collected (one file|batch)|Decompressing|Next batch expected" | tail -1 || true)
        if [[ -n "$PHASE_LINE" ]]; then
            if echo "$PHASE_LINE" | grep -q "Successfully applied"; then
                PHASE="idle"
            elif echo "$PHASE_LINE" | grep -q "Next batch expected"; then
                PHASE="waiting for next batch"
            elif echo "$PHASE_LINE" | grep -q "Applying batch"; then
                PHASE="applying to database"
            elif echo "$PHASE_LINE" | grep -q "Decompressing"; then
                PHASE="decompressing"
            elif echo "$PHASE_LINE" | grep -q "Collected"; then
                PHASE="collected, preparing"
            fi
            kv "phase" "$PHASE"
        fi
    else
        kv "log" "not found"
    fi

    UPDATE_PID=$(find_proc_pid "update_from_dir")
    kv "update_from_dir" "$(pid_status "${UPDATE_PID:-}")"
fi

# ============================================================================
# FETCH_OSC
# ============================================================================

section "fetch_osc.sh"

FETCH_PID=$(find_proc_pid "fetch_osc.sh")
kv "status" "$(pid_status "${FETCH_PID:-}")"

DIFF_DIR=""
if [[ -n "$FETCH_PID" ]]; then
    DIFF_DIR=$(tr '\0' '\n' < "/proc/$FETCH_PID/cmdline" 2>/dev/null | awk '/^http/{found=1; next} found && /^\// {print; exit}' || true)
fi
DIFF_DIR="${DIFF_DIR:-/opt/overpass/diff}"

FETCH_STATE=$(cat "$DIFF_DIR/replicate_id" 2>/dev/null || true)
kv "replicate_id" "${FETCH_STATE:-unknown}"

FETCH_LOG="$DIFF_DIR/fetch_osc.log"
if [[ -f "$FETCH_LOG" ]]; then
    LAST_DL=$(read_log "$FETCH_LOG" | grep "Downloaded" | tail -1 || true)
    if [[ -n "$LAST_DL" ]]; then
        LAST_DL_TIME=$(echo "$LAST_DL" | awk '{print $1, substr($2, 1, length($2)-1)}')
        kv "last download" "$LAST_DL_TIME"
    fi

    PHASE_LINE=$(read_log "$FETCH_LOG" | grep -E "Downloaded|Fetching|Waiting for file|Sleeping until" | tail -1 || true)
    if [[ -n "$PHASE_LINE" ]]; then
        if echo "$PHASE_LINE" | grep -q "Downloaded"; then
            PHASE="idle"
        elif echo "$PHASE_LINE" | grep -q "Fetching"; then
            PHASE="fetching"
        elif echo "$PHASE_LINE" | grep -q "Waiting for file"; then
            PHASE="waiting for next file"
        elif echo "$PHASE_LINE" | grep -q "Sleeping until"; then
            NEXT_TIME=$(echo "$PHASE_LINE" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}' | tail -1)
            PHASE="sleeping until $NEXT_TIME"
        fi
        kv "phase" "$PHASE"
    fi
else
    kv "log" "not found"
fi

OSC_COUNT=$(find "$DIFF_DIR" -name "*.osc.gz" 2>/dev/null | wc -l)
OSC_SIZE=$(du -sh "$DIFF_DIR" 2>/dev/null | awk '{print $1}')
kv "diff cache" "$OSC_COUNT files  ($OSC_SIZE)"

CURL_PID=$(find_proc_pid "curl")
WGET_PID=$(find_proc_pid "wget")
if [[ -n "$CURL_PID" ]]; then
    kv "download" "curl $(pid_status "$CURL_PID")"
elif [[ -n "$WGET_PID" ]]; then
    kv "download" "wget $(pid_status "$WGET_PID")"
else
    kv "download" "not running"
fi

# ============================================================================
# BACKUP
# ============================================================================

section "backup.sh"

BACKUP_PID=$(find_proc_pid "backup.sh")
kv "status" "$(pid_status "${BACKUP_PID:-}")"

RSYNC_PID=$(find_proc_pid "rsync")
kv "rsync" "$(pid_status "${RSYNC_PID:-}")"

if [[ -n "$BACKUP_PID" ]]; then
    if [[ -n "$RSYNC_PID" ]]; then
        kv "phase" "backing up"
    else
        kv "phase" "sleeping"
    fi
fi

if [[ -n "$DB_DIR" ]]; then
    BACKUP_LOG="$DB_DIR/backup.log"
    if [[ -f "$BACKUP_LOG" ]]; then
        LAST_STARTED=$(read_log "$BACKUP_LOG" | grep "Backup started" | tail -1 || true)
        [[ -n "$LAST_STARTED" ]] && kv "last backup started" "$(echo "$LAST_STARTED" | awk '{print $1, substr($2, 1, length($2)-1)}')"

        LAST_COMPLETE=$(read_log "$BACKUP_LOG" | grep "Backup complete" | tail -1 || true)
        [[ -n "$LAST_COMPLETE" ]] && kv "last backup complete" "$(echo "$LAST_COMPLETE" | awk '{print $1, substr($2, 1, length($2)-1)}')"
    else
        kv "log" "not found"
    fi
fi

# ============================================================================
# RULES LOOP
# ============================================================================

section "rules_loop.sh"

RULES_PID=$(find_proc_pid "rules_loop.sh")
kv "status" "$(pid_status "${RULES_PID:-}")"

QUERY_PID=$(find_proc_pid "osm3s_query")
kv "osm3s_query" "$(pid_status "${QUERY_PID:-}")"

if [[ -n "$DB_DIR" ]]; then
    RULES_LOG="$DB_DIR/rules_loop.log"
    if [[ -f "$RULES_LOG" ]]; then
        LAST_STARTED=$(read_log "$RULES_LOG" | grep "Area update started" | tail -1 || true)
        [[ -n "$LAST_STARTED" ]] && kv "last area gen started" "$(echo "$LAST_STARTED" | awk '{print $1, substr($2, 1, length($2)-1)}')"

        LAST_FINISHED=$(read_log "$RULES_LOG" | grep -E "Area update finished|Area update failed" | tail -1 || true)
        [[ -n "$LAST_FINISHED" ]] && kv "last area gen finished" "$(echo "$LAST_FINISHED" | awk '{print $1, substr($2, 1, length($2)-1)}')"

        PHASE_LINE=$(read_log "$RULES_LOG" | grep -E "Area update started|Area update finished|Area update failed|Sleeping for" | tail -1 || true)
        if [[ -n "$PHASE_LINE" ]]; then
            if echo "$PHASE_LINE" | grep -q "Area update started"; then
                PHASE="generating areas"
            elif echo "$PHASE_LINE" | grep -q "Area update finished"; then
                PHASE="idle"
            elif echo "$PHASE_LINE" | grep -q "Area update failed"; then
                PHASE="idle (last run failed)"
            elif echo "$PHASE_LINE" | grep -q "Sleeping for"; then
                PHASE="sleeping"
            fi
            kv "phase" "$PHASE"
        fi
    else
        kv "log" "not found"
    fi
fi

# ============================================================================
# INTERPRETER
# ============================================================================

section "interpreter"

RATE_LIMIT=$(curl -sf http://127.0.0.1:8080/api/status 2>/dev/null | awk '/^Rate limit:/ {print $3}' || true)
kv "rate limit" "${RATE_LIMIT:-unavailable}"

mapfile -t QUERY_PIDS < <(find_all_proc_pids "osm3s_query")
kv "running queries" "${#QUERY_PIDS[@]}"
for pid in "${QUERY_PIDS[@]}"; do
    printf '  %s\n' "$(proc_stats "$pid")"
done


# ============================================================================
# HOST
# ============================================================================

section "Host"

while IFS= read -r mountpoint; do
    kv "$mountpoint" "$(df -h "$mountpoint" 2>/dev/null | awk 'NR==2 {print $3 " used / " $2 " total (" $5 " full)"}')"
done < <(awk '$2 ~ /^\/opt\/overpass\// {print $2}' /proc/mounts | sort)
kv "memory" "$(awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {avail=$2} END {
    used = total - avail
    printf "%.1fG used / %.1fG total\n", used/1048576, total/1048576
}' /proc/meminfo)"
kv "load average" "$(awk '{printf "1m: %s  5m: %s  15m: %s\n", $1, $2, $3}' /proc/loadavg)"
