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
# Script: container_status.sh
# Purpose: Reports on the operational status of the Overpass API container.
#          Outputs plain text. Designed to be served via nginx at
#          /container_status using fcgiwrap.
# ============================================================================

set -euo pipefail

EXEC_DIR="$(realpath "$(dirname "$0")")"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

FORMAT=$(printf '%s' "${QUERY_STRING:-}" | tr '[:upper:]' '[:lower:]' | tr '&' '\n' \
    | grep '^format=' | cut -d= -f2 | head -1 || true)
FORMAT="${FORMAT:-text}"

PARSED=$(getopt --options '' --longoptions 'format:' --name "$0" -- "$@") \
    || { printf 'Usage: %s [--format=text|json]\n' "$0" >&2; exit 1; }
eval set -- "$PARSED"

while true; do
    case "$1" in
        --format) FORMAT=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'); shift 2 ;;
        --) shift; break ;;
    esac
done

if [[ "$FORMAT" != "text" && "$FORMAT" != "json" ]]; then
    printf 'Error: unknown format %q (expected text or json)\n' "$FORMAT" >&2
    exit 1
fi

# CGI header (omit when running interactively)
if [[ ! -t 1 ]]; then
    if [[ "$FORMAT" == "json" ]]; then
        printf 'Content-Type: application/json\r\n\r\n'
    else
        printf 'Content-Type: text/plain\r\n\r\n'
    fi
fi

REPORT_TIME="$(date -u '+%Y-%m-%d %H:%M:%S') UTC"

# ============================================================================
# HELPERS
# ============================================================================

SEPARATOR="-----------------------------------"
DEPTH=0
declare -a _JSON_COMMA=()

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

begin_section() {
    local name="$1"
    if [[ "$FORMAT" == "json" ]]; then
        if [[ "${_JSON_COMMA[$DEPTH]:-0}" == "1" ]]; then printf ','; fi
        printf '\n%*s"%s":\n%*s{' $(( DEPTH * 2 )) '' "$(json_escape "$name")" $(( DEPTH * 2 )) ''
        _JSON_COMMA[$DEPTH]=1
        DEPTH=$(( DEPTH + 1 ))
        _JSON_COMMA[$DEPTH]=0
    else
        if (( DEPTH == 0 )); then
            printf '\n%s\n%s\n%s\n' "$SEPARATOR" "$name" "$SEPARATOR"
        else
            printf '\n%s\n' "$name"
        fi
        DEPTH=$(( DEPTH + 1 ))
    fi
}

end_section() {
    if [[ "$FORMAT" == "json" ]]; then
        printf '\n'
        DEPTH=$(( DEPTH - 1 ))
        printf '%*s}' $(( DEPTH * 2 )) ''
        _JSON_COMMA[$DEPTH]=1
    else
        DEPTH=$(( DEPTH - 1 ))
    fi
}

kv() {
    local key="$1" val="$2"
    if [[ "$FORMAT" == "json" ]]; then
        if [[ "${_JSON_COMMA[$DEPTH]:-0}" == "1" ]]; then printf ','; fi
        printf '\n%*s"%s": "%s"' $(( DEPTH * 2 )) '' "$(json_escape "$key")" "$(json_escape "$val")"
        _JSON_COMMA[$DEPTH]=1
    else
        local indent=$(( (DEPTH - 1) * 2 ))
        if (( indent > 0 )); then
            printf '%*s%-*s %s\n' "$indent" '' $(( 34 - indent )) "$key" "$val"
        else
            printf '%-34s %s\n' "$key" "$val"
        fi
    fi
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

socket_status() {
    local path="$1"
    if [[ ! -S "$path" ]]; then
        echo "missing"
        return
    fi
    local norm_path
    norm_path=$(realpath "$path")
    local ss_path
    while IFS= read -r ss_path; do
        if [[ "$(realpath "$ss_path" 2>/dev/null)" == "$norm_path" ]]; then
            echo "live"
            return
        fi
    done < <(ss -lx 2>/dev/null | awk '{print $5}' | grep -v '^*$')
    echo "stale"
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
# DOCUMENT
# ============================================================================

if [[ "$FORMAT" == "json" ]]; then
    printf '{'
    DEPTH=1
    _JSON_COMMA[1]=0
    kv "Status report" "$REPORT_TIME"
else
    printf 'Status report: %s\n' "$REPORT_TIME"
fi

# ============================================================================
# NGINX / FCGIWRAP
# ============================================================================

begin_section "nginx / fcgiwrap"

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
    begin_section "requests"
    while IFS=$'\t' read -r key val; do
        kv "$key" "$val"
    done < <(awk '
        function clf_to_iso(d,    parts, months, m) {
            gsub(/^\[/, "", d)
            split(d, parts, /[\/:]/)
            split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", months)
            for (m = 1; m <= 12; m++)
                if (months[m] == parts[2]) break
            return parts[3] "-" sprintf("%02d", m) "-" sprintf("%02d", parts[1]+0) \
                   " " parts[4] ":" parts[5] ":" parts[6]
        }
        NF >= 9 {
            total++
            counts[$9]++
            if (total == 1) first = $4
            last = $4
        }
        END {
            n = 0
            for (code in counts) codes[++n] = code
            for (i = 2; i <= n; i++) {
                c = codes[i]; j = i - 1
                while (j >= 1 && codes[j] > c) { codes[j+1] = codes[j]; j-- }
                codes[j+1] = c
            }
            for (i = 1; i <= n; i++)
                print "HTTP " codes[i] "\t" counts[codes[i]]
            print "total\t" total
            print "interval\t" clf_to_iso(first) " to " clf_to_iso(last)
        }
    ' "$ACCESS_LOG")
    end_section
else
    kv "access log" "not found"
fi

end_section

# ============================================================================
# BASE DISPATCHER / DATABASE
# ============================================================================

begin_section "Base Dispatcher"

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
    kv "socket" "$(socket_status "$DB_DIR/osm3s_osm_base")"
fi

end_section

# ============================================================================
# AREAS DISPATCHER
# ============================================================================

begin_section "Areas Dispatcher"

if "$EXEC_DIR/dispatcher" --areas --show-dir > /dev/null 2>&1; then
    kv "status" "running"
else
    kv "status" "not running"
fi

if [[ -n "$DB_DIR" ]]; then
    kv "areas lock" "$(lock_status "$DB_DIR/areas_shadow.lock")"

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
        if [[ -f "$DB_DIR/$f" ]]; then (( area_present++ )) || true; fi
    done
    AREA_VERSION=$(cat "$DB_DIR/area_version" 2>/dev/null || true)
    if (( area_present == area_total )); then
        kv "area files" "present ($area_present/$area_total)"
    elif (( area_present == 0 )); then
        kv "area files" "missing"
    else
        kv "area files" "partial ($area_present/$area_total)"
    fi
    if [[ -n "$AREA_VERSION" ]]; then kv "area version" "$AREA_VERSION"; fi
    kv "socket" "$(socket_status "$DB_DIR/osm3s_areas")"
fi

end_section

# ============================================================================
# APPLY_OSC_TO_DB
# ============================================================================

begin_section "apply_osc_to_db.sh"

if [[ -n "$DB_DIR" ]]; then
    APPLY_PID=$(cat "$DB_DIR/apply_osc.pid" 2>/dev/null || true)
    kv "status" "$(pid_status "$APPLY_PID")"

    APPLY_LOG="$DB_DIR/apply_osc_to_db.log"
    if [[ -f "$APPLY_LOG" ]]; then
        LAST_APPLY=$(read_log "$APPLY_LOG" | grep "Successfully applied batch up to" | tail -1 || true)
        if [[ -n "$LAST_APPLY" ]]; then
            LAST_APPLY_TIME=$(echo "$LAST_APPLY" | awk '{print $1, substr($2, 1, length($2)-1)}')
            LAST_APPLY_ID=$(echo "$LAST_APPLY" | grep -o '[0-9]*$')
            kv "last replicate_id" "$LAST_APPLY_ID"
            kv "last update" "$LAST_APPLY_TIME"
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
        INTERVAL_STATS=$(read_log "$APPLY_LOG" | awk '
            function to_epoch(date, time,    d, t, y, mo, dy, hr, mn, sc, days, i, mdays) {
                split(date, d, "-"); split(time, t, ":")
                y = d[1]+0; mo = d[2]+0; dy = d[3]+0
                hr = t[1]+0; mn = t[2]+0; sc = t[3]+0
                split("31 28 31 30 31 30 31 31 30 31 30 31", mdays, " ")
                if ((y%4==0 && y%100!=0) || y%400==0) mdays[2] = 29
                days = (y-1970)*365
                for (i=1970; i<y; i++)
                    if ((i%4==0 && i%100!=0) || i%400==0) days++
                for (i=1; i<mo; i++) days += mdays[i]
                return (days + dy - 1) * 86400 + hr*3600 + mn*60 + sc
            }
            /Successfully applied batch up to/ {
                gsub(/:$/, "", $2)
                e = to_epoch($1, $2)
                if (prev > 0) {
                    interval = e - prev
                    sum += interval
                    sumsq += interval * interval
                    n++
                }
                prev = e
            }
            END {
                if (n < 2) { print "insufficient data"; exit }
                mean = sum / n
                variance = sumsq/n - mean*mean
                stddev = variance > 0 ? sqrt(variance) : 0
                if (mean >= 3600)
                    printf "%.1fh avg  +/-%.1fm  (%d samples)\n", mean/3600, stddev/60, n
                else if (mean >= 60)
                    printf "%.1fm avg  +/-%ds  (%d samples)\n", mean/60, int(stddev), n
                else
                    printf "%ds avg  +/-%ds  (%d samples)\n", int(mean), int(stddev), n
            }
        ' || true)
        [[ -n "$INTERVAL_STATS" ]] && kv "update interval" "$INTERVAL_STATS"
    else
        kv "log" "not found"
    fi

    UPDATE_PID=$(find_proc_pid "update_from_dir")
    kv "update_from_dir" "$(pid_status "${UPDATE_PID:-}")"
fi

end_section

# ============================================================================
# FETCH_OSC
# ============================================================================

begin_section "fetch_osc.sh"

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

    INTERVAL_STATS=$(read_log "$FETCH_LOG" | awk '
        function to_epoch(date, time,    d, t, y, mo, dy, hr, mn, sc, days, i, mdays) {
            split(date, d, "-"); split(time, t, ":")
            y = d[1]+0; mo = d[2]+0; dy = d[3]+0
            hr = t[1]+0; mn = t[2]+0; sc = t[3]+0
            split("31 28 31 30 31 30 31 31 30 31 30 31", mdays, " ")
            if ((y%4==0 && y%100!=0) || y%400==0) mdays[2] = 29
            days = (y-1970)*365
            for (i=1970; i<y; i++)
                if ((i%4==0 && i%100!=0) || i%400==0) days++
            for (i=1; i<mo; i++) days += mdays[i]
            return (days + dy - 1) * 86400 + hr*3600 + mn*60 + sc
        }
        /Downloaded/ {
            gsub(/:$/, "", $2)
            e = to_epoch($1, $2)
            if (prev > 0) {
                interval = e - prev
                sum += interval
                sumsq += interval * interval
                n++
            }
            prev = e
        }
        END {
            if (n < 2) { print "insufficient data"; exit }
            mean = sum / n
            variance = sumsq/n - mean*mean
            stddev = variance > 0 ? sqrt(variance) : 0
            if (mean >= 3600)
                printf "%.1fh avg  +/-%.1fm  (%d samples)\n", mean/3600, stddev/60, n
            else if (mean >= 60)
                printf "%.1fm avg  +/-%ds  (%d samples)\n", mean/60, int(stddev), n
            else
                printf "%ds avg  +/-%ds  (%d samples)\n", int(mean), int(stddev), n
        }
    ' || true)
    [[ -n "$INTERVAL_STATS" ]] && kv "download interval" "$INTERVAL_STATS"
else
    kv "log" "not found"
fi

CURL_PID=$(find_proc_pid "curl")
WGET_PID=$(find_proc_pid "wget")
if [[ -n "$CURL_PID" ]]; then
    kv "download" "curl $(pid_status "$CURL_PID")"
elif [[ -n "$WGET_PID" ]]; then
    kv "download" "wget $(pid_status "$WGET_PID")"
else
    kv "download" "not running"
fi

end_section

# ============================================================================
# BACKUP
# ============================================================================

begin_section "backup.sh"

BACKUP_PID=$(find_proc_pid "backup.sh")
kv "status" "$(pid_status "${BACKUP_PID:-}")"

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

if [[ -n "$BACKUP_PID" ]]; then
    if [[ -n "$RSYNC_PID" ]]; then
        kv "phase" "backing up"
    else
        kv "phase" "sleeping"
    fi
fi

RSYNC_PID=$(find_proc_pid "rsync")
kv "rsync" "$(pid_status "${RSYNC_PID:-}")"

end_section

# ============================================================================
# RULES LOOP
# ============================================================================

begin_section "rules_loop.sh"

RULES_PID=$(find_proc_pid "rules_loop.sh")
kv "status" "$(pid_status "${RULES_PID:-}")"

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

QUERY_PID=$(find_proc_pid "osm3s_query")
kv "osm3s_query" "$(pid_status "${QUERY_PID:-}")"

end_section

# ============================================================================
# LOG ROTATION
# ============================================================================

begin_section "Log Rotation"

LAST_ROTATION_EPOCH=0
LAST_ROTATION="unknown"
while IFS= read -r f; do
    ctime=$(stat -c %Z "$f" 2>/dev/null) || continue
    if (( ctime > LAST_ROTATION_EPOCH )); then
        LAST_ROTATION_EPOCH=$ctime
        LAST_ROTATION=$(date -d "@$ctime" -u '+%Y-%m-%d %H:%M:%S')
    fi
done < <(find /opt/overpass -maxdepth 2 \( -name "*.log.1" -o -name "*.out.1" \) -type f 2>/dev/null)
kv "last rotation" "$LAST_ROTATION"

LOG_SIZE=$(find /opt/overpass -maxdepth 2 -name "*.log*" -type f -print0 2>/dev/null \
    | xargs -r -0 stat -c %s 2>/dev/null \
    | awk '{s+=$1} END {printf "%.1fM\n", s/1048576}')
kv "log files (.log*)" "${LOG_SIZE:-0}"

OUT_SIZE=$(find /opt/overpass -maxdepth 2 -name "*.out*" -type f -print0 2>/dev/null \
    | xargs -r -0 stat -c %s 2>/dev/null \
    | awk '{s+=$1} END {printf "%.1fM\n", s/1048576}')
kv "out files (.out*)" "${OUT_SIZE:-0}"

end_section

# ============================================================================
# clean_osc.sh
# ============================================================================

begin_section "clean_osc.sh"

CLEAN_PID=$(find_proc_pid "clean_osc.sh")
kv "status" "$(pid_status "${CLEAN_PID:-}")"

CLEAN_LOG="$DIFF_DIR/clean_osc.out"
if [[ -f "$CLEAN_LOG" ]]; then
    LAST_RUN=$(read_log "$CLEAN_LOG" | grep "Starting Cleanup Process" | tail -1 || true)
    if [[ -n "$LAST_RUN" ]]; then
        kv "last run" "$(echo "$LAST_RUN" | awk '{print $1, substr($2, 1, length($2)-1)}')"
    fi

    LAST_RESULT=$(read_log "$CLEAN_LOG" | grep -E "Cleaned up|No files needed cleaning|nothing to clean" | tail -1 || true)
    if [[ -n "$LAST_RESULT" ]]; then
        kv "last result" "${LAST_RESULT##*: }"
    fi
else
    kv "log" "not found"
fi

OSC_COUNT=$(find "$DIFF_DIR" -name "*.osc.gz" 2>/dev/null | wc -l)
OSC_SIZE=$(du -sh "$DIFF_DIR" 2>/dev/null | awk '{print $1}')
kv "diff cache" "$OSC_COUNT files  ($OSC_SIZE)"

end_section

# ============================================================================
# INTERPRETER
# ============================================================================

begin_section "interpreter"

RATE_LIMIT=$(curl -sf http://127.0.0.1:8080/api/status 2>/dev/null | awk '/^Rate limit:/ {print $3}' || true)
kv "rate limit" "${RATE_LIMIT:-unavailable}"

mapfile -t QUERY_PIDS < <(find_all_proc_pids "osm3s_query")
kv "running queries" "${#QUERY_PIDS[@]}"
for pid in "${QUERY_PIDS[@]}"; do
    kv "query $pid" "$(proc_stats "$pid")"
done

end_section


# ============================================================================
# HOST
# ============================================================================

begin_section "Host"

begin_section "file systems"
while IFS= read -r mountpoint; do
    kv "$mountpoint" "$(df -h "$mountpoint" 2>/dev/null | awk 'NR==2 {print $3 " used / " $2 " total (" $5 " full)"}')"
done < <(awk '$2 ~ /^\/opt\/overpass\// {print $2}' /proc/mounts | sort)
end_section

begin_section "directories"
for dir in /opt/overpass/backup /opt/overpass/db /opt/overpass/diff /opt/overpass/log /opt/overpass/run; do
    [[ -d "$dir" ]] || continue
    kv "$dir" "$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
done
end_section

kv "memory" "$(awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {avail=$2} END {
    used = total - avail
    printf "%.1fG used / %.1fG total\n", used/1048576, total/1048576
}' /proc/meminfo)"
kv "load average" "$(awk '{printf "1m: %s  5m: %s  15m: %s\n", $1, $2, $3}' /proc/loadavg)"

end_section

if [[ "$FORMAT" == "json" ]]; then
    printf '\n}\n'
fi