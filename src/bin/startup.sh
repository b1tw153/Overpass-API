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
# Robust startup script for Overpass API v0.7.61.4
# Ensures sequential startup with proper verification and cleanup
# ============================================================================

set -o pipefail

# Configuration
EXEC_DIR="/opt/overpass/bin"
DB_DIR="/opt/overpass/db"
DIFF_DIR="/opt/overpass/diff"
LOG_DIR="/opt/overpass/log"

# Process definitions
declare -A PROCESSES=(
    [base_dispatcher]="dispatcher --osm-base"
    [area_dispatcher]="dispatcher --areas"
    [apply_osc]="apply_osc_to_db.sh"
    [fetch_osc]="fetch_osc.sh"
)

# Startup order
STARTUP_ORDER=("base_dispatcher" "area_dispatcher" "apply_osc" "fetch_osc")

# Cleanup files
CLEANUP_FILES=(
    "/dev/shm/osm3s_osm_base"
    "/dev/shm/osm3s_areas"
    "${DB_DIR}/osm3s_osm_base"
    "${DB_DIR}/osm3s_areas"
)

# Maximum retries for process verification
MAX_RETRIES=5
RETRY_DELAY=2

# Log function with timestamp
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${level}: $*"
}

# Get PID of a process by matching its command line
get_pid() {
    local process_pattern="$1"
    pgrep -f "${process_pattern}" | head -n 1
}

# Check if a process is running
is_running() {
    local process_name="$1"
    local process_pattern="${PROCESSES[$process_name]}"
    local pid
    
    pid=$(get_pid "${process_pattern}")
    
    if [[ -n "${pid}" ]]; then
        return 0
    else
        return 1
    fi
}

# Wait for a process to start with retries
wait_for_process() {
    local process_name="$1"
    local max_retries="${2:-$MAX_RETRIES}"
    local retry_count=0
    
    while [[ ${retry_count} -lt ${max_retries} ]]; do
        if is_running "${process_name}"; then
            local pid
            pid=$(get_pid "${PROCESSES[$process_name]}")
            log "INFO" "${process_name} is running (PID: ${pid})"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        if [[ ${retry_count} -lt ${max_retries} ]]; then
            log "INFO" "Waiting for ${process_name} to start (attempt ${retry_count}/${max_retries})..."
            sleep "${RETRY_DELAY}"
        fi
    done
    
    log "ERROR" "${process_name} failed to start after ${max_retries} attempts"
    return 1
}

# Clean up stale files after crashes
cleanup_files() {
    log "INFO" "Cleaning up stale files..."
    
    for file in "${CLEANUP_FILES[@]}"; do
        if [[ -e "${file}" ]]; then
            if rm -f "${file}"; then
                log "INFO" "Removed ${file}"
            else
                log "WARNING" "Failed to remove ${file}"
            fi
        fi
    done
}

# Shutdown all processes
shutdown_all() {
    log "INFO" "Shutting down all Overpass components..."
    
    if [[ ! -x "${EXEC_DIR}/shutdown.sh" ]]; then
        log "ERROR" "shutdown.sh not found or not executable at ${EXEC_DIR}/shutdown.sh"
        exit 1
    fi
    
    "${EXEC_DIR}/shutdown.sh"
}

# Start a specific process
start_process() {
    local process_name="$1"
    
    # Check if already running
    if is_running "${process_name}"; then
        local pid
        pid=$(get_pid "${PROCESSES[$process_name]}")
        log "WARNING" "${process_name} is already running (PID: ${pid})"
        return 0
    fi
    
    log "INFO" "Starting ${process_name}..."
    
    # Start the appropriate process
    case "${process_name}" in
        base_dispatcher)
            cleanup_files
            ionice -c 2 -n 7 nice -n 17 nohup "${EXEC_DIR}/dispatcher" \
                --osm-base --meta --allow-duplicate-queries=yes \
                --space=10737418240 --db-dir="${DB_DIR}" \
                >> "${LOG_DIR}/osm_base.out" 2>&1 &
            ;;
        
        area_dispatcher)
            ionice -c 3 nice -n 19 nohup "${EXEC_DIR}/dispatcher" \
                --areas --db-dir="${DB_DIR}" \
                >> "${LOG_DIR}/areas.out" 2>&1 &
            ;;
        
        apply_osc)
            ionice -c 2 -n 7 nice -n 17 nohup "${EXEC_DIR}/apply_osc_to_db.sh" \
                "${DIFF_DIR}" auto --meta=yes \
                >> "${LOG_DIR}/apply_osc_to_db.out" 2>&1 &
            ;;
        
        fetch_osc)
            ionice -c 3 nice -n 19 nohup "${EXEC_DIR}/fetch_osc.sh" \
                auto "https://planet.openstreetmap.org/replication/minute" \
                "${DIFF_DIR}" \
                >> "${LOG_DIR}/fetch_osc.out" 2>&1 &
            ;;
        
        *)
            log "ERROR" "Unknown process: ${process_name}"
            return 1
            ;;
    esac
    
    # Wait for process to start and verify
    if ! wait_for_process "${process_name}"; then
        return 1
    fi
    
    return 0
}

# Main startup routine
main() {
    log "INFO" "Starting Overpass API components..."
    
    # Verify required directories exist
    for dir in "${EXEC_DIR}" "${DB_DIR}" "${DIFF_DIR}" "${LOG_DIR}"; do
        if [[ ! -d "${dir}" ]]; then
            log "ERROR" "Required directory does not exist: ${dir}"
            exit 1
        fi
    done
    
    # Verify required executables exist
    for executable in dispatcher apply_osc_to_db.sh fetch_osc.sh shutdown.sh; do
        if [[ ! -x "${EXEC_DIR}/${executable}" ]]; then
            log "ERROR" "Required executable not found or not executable: ${EXEC_DIR}/${executable}"
            exit 1
        fi
    done
    
    # Start processes in order
    local all_started=true
    
    for process_name in "${STARTUP_ORDER[@]}"; do
        if ! start_process "${process_name}"; then
            log "ERROR" "Failed to start ${process_name}"
            all_started=false
            break
        fi
    done
    
    # If any process failed to start, shut down everything
    if [[ "${all_started}" != "true" ]]; then
        log "ERROR" "Startup failed, cleaning up..."
        shutdown_all
        exit 1
    fi
    
    # Final verification
    log "INFO" "Performing final verification..."
    sleep 2
    
    local all_verified=true
    for process_name in "${STARTUP_ORDER[@]}"; do
        if ! is_running "${process_name}"; then
            local pid
            pid=$(get_pid "${PROCESSES[$process_name]}")
            log "ERROR" "${process_name} is not running"
            all_verified=false
        else
            local pid
            pid=$(get_pid "${PROCESSES[$process_name]}")
            log "INFO" "${process_name} verified (PID: ${pid})"
        fi
    done
    
    if [[ "${all_verified}" != "true" ]]; then
        log "ERROR" "Verification failed, shutting down..."
        shutdown_all
        exit 1
    fi
    
    log "INFO" "All Overpass components started successfully"
    
    # Display status summary
    echo ""
    log "INFO" "=== Process Status ==="
    for process_name in "${STARTUP_ORDER[@]}"; do
        local pid
        pid=$(get_pid "${PROCESSES[$process_name]}")
        printf "  %-20s PID: %s\n" "${process_name}" "${pid}"
    done
    echo ""
    
    exit 0
}

# Run main function
main "$@"
