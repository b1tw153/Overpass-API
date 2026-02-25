#!/usr/bin/env bash

# Robust shutdown script for Overpass API v0.7.61.4
# Ensures graceful shutdown in reverse startup order

set -o pipefail

# Configuration
EXEC_DIR="/opt/overpass/bin"
DB_DIR="/opt/overpass/db"
DIFF_DIR="/opt/overpass/diff"
LOG_DIR="/opt/overpass/log"

# Process definitions (must match startup.sh)
declare -A PROCESSES=(
    [base_dispatcher]="dispatcher --osm-base"
    [area_dispatcher]="dispatcher --areas"
    [apply_osc]="apply_osc_to_db.sh"
    [fetch_osc]="fetch_osc.sh"
    [area_updater]="osm3s_query --progress --rules"
    [area_script]="area_updater.sh"
)

# Shutdown order (reverse of startup)
SHUTDOWN_ORDER=("fetch_osc" "apply_osc" "area_script" "area_updater" "area_dispatcher" "base_dispatcher")

# Timeouts
MAX_WAIT_ITERATIONS=100
APPLY_OSC_POLL_INTERVAL=6
AREA_UPDATER_POLL_INTERVAL=15
DEFAULT_POLL_INTERVAL=3

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

# Wait for a process to terminate gracefully
wait_for_termination() {
    local process_name="$1"
    local max_iterations="${2:-$MAX_WAIT_ITERATIONS}"
    local poll_interval="${3:-$DEFAULT_POLL_INTERVAL}"
    local iteration=0
    
    while [[ ${iteration} -lt ${max_iterations} ]]; do
        if ! is_running "${process_name}"; then
            log "INFO" "${process_name} has terminated"
            return 0
        fi
        
        iteration=$((iteration + 1))
        
        if [[ ${iteration} -lt ${max_iterations} ]]; then
            sleep "${poll_interval}"
        fi
    done
    
    log "ERROR" "${process_name} did not terminate after ${max_iterations} attempts"
    return 1
}

# Stop fetch_osc.sh
stop_fetch_osc() {
    local process_name="fetch_osc"
    
    if ! is_running "${process_name}"; then
        log "WARNING" "${process_name} is not running"
        return 0
    fi
    
    local pid
    pid=$(get_pid "${PROCESSES[$process_name]}")
    log "INFO" "Stopping ${process_name} (PID: ${pid})"
    log "INFO" "Waiting for ${process_name} to complete current download batch and cleanup..."
    
    # Send SIGTERM (fetch_osc.sh has a proper signal handler)
    if kill -TERM "${pid}" 2>/dev/null; then
        # Wait longer for fetch_osc.sh since it may be:
        # - In the middle of a batch download (up to 360 files)
        # - Sleeping between retries (up to 60 seconds)
        # - Cleaning up temporary files
        # Give it up to 2 minutes to finish gracefully
        if wait_for_termination "${process_name}" 40 3; then
            return 0
        else
            log "ERROR" "Failed to stop ${process_name} after 2 minutes"
            return 1
        fi
    else
        log "ERROR" "Failed to send signal to ${process_name}"
        return 1
    fi
}

# Stop apply_osc_to_db.sh (wait for it to be idle first)
stop_apply_osc() {
    local process_name="apply_osc"
    
    if ! is_running "${process_name}"; then
        log "WARNING" "${process_name} is not running"
        return 0
    fi
    
    local pid
    pid=$(get_pid "${PROCESSES[$process_name]}")
    log "INFO" "Stopping ${process_name} (PID: ${pid})"
    log "INFO" "Waiting for ${process_name} to finish applying current batch..."
    
    # Check if currently applying a batch (log shows recent activity)
    local log_file="${DB_DIR}/apply_osc_to_db.log"
    if [[ -f "${log_file}" ]]; then
        local recent_activity
        recent_activity=$(tail -n 10 "${log_file}" 2>/dev/null | grep -cE "Applying batch|Decompressing batch") || recent_activity=0
        
        if [[ ${recent_activity} -gt 0 ]]; then
            log "INFO" "${process_name} is currently applying a batch, waiting for completion..."
            
            # Wait for batch application to complete (check every 10 seconds)
            local wait_count=0
            local max_batch_wait=180  # 30 minutes max (180 * 10 seconds)
            
            while [[ ${wait_count} -lt ${max_batch_wait} ]]; do
                sleep 10
                
                # Check if batch application finished (look for success message)
                local completed
                completed=$(tail -n 5 "${log_file}" 2>/dev/null | grep -cE "Successfully applied batch|No new OSC files available") || completed=0
                
                if [[ ${completed} -gt 0 ]]; then
                    log "INFO" "${process_name} completed its batch application"
                    break
                fi
                
                # Verify process is still running
                if ! is_running "${process_name}"; then
                    log "INFO" "${process_name} has already stopped"
                    return 0
                fi
                
                wait_count=$((wait_count + 1))
                
                if [[ $((wait_count % 6)) -eq 0 ]]; then
                    log "INFO" "Still waiting for ${process_name} to complete batch ($((wait_count * 10)) seconds elapsed)..."
                fi
            done
            
            if [[ ${wait_count} -eq ${max_batch_wait} ]]; then
                log "WARNING" "${process_name} batch application did not complete after 30 minutes, stopping anyway"
            fi
        fi
    fi
    
    # Now send SIGTERM (apply_osc_to_db.sh has proper signal handling)
    log "INFO" "Sending shutdown signal to ${process_name}"
    if kill -TERM "${pid}" 2>/dev/null; then
        # The script should respond quickly to SIGTERM now that batch is done
        # Give it up to 30 seconds to clean up work files
        if wait_for_termination "${process_name}" 10 6; then
            return 0
        else
            log "ERROR" "Failed to stop ${process_name} after sending SIGTERM"
            return 1
        fi
    else
        log "ERROR" "Failed to send signal to ${process_name}"
        return 1
    fi
}

# Stop area_updater.sh script
stop_area_script() {
    local process_name="area_script"
    
    if ! is_running "${process_name}"; then
        log "WARNING" "${process_name} is not running"
        return 0
    fi
    
    local pid
    pid=$(get_pid "${PROCESSES[$process_name]}")
    log "INFO" "Stopping ${process_name} (PID: ${pid})"
    
    if kill "${pid}" 2>/dev/null; then
        sleep 1
        
        if wait_for_termination "${process_name}" 10 1; then
            return 0
        else
            log "ERROR" "Failed to stop ${process_name}"
            return 1
        fi
    else
        log "ERROR" "Failed to send signal to ${process_name}"
        return 1
    fi
}

# Wait for area updater query to complete
wait_area_updater() {
    local process_name="area_updater"
    
    if ! is_running "${process_name}"; then
        log "INFO" "${process_name} is not running"
        return 0
    fi
    
    local pid
    pid=$(get_pid "${PROCESSES[$process_name]}")
    log "INFO" "Waiting for ${process_name} to finish - this may take a long time (PID: ${pid})"
    
    # Wait indefinitely for area updater (no max iterations)
    while is_running "${process_name}"; do
        sleep "${AREA_UPDATER_POLL_INTERVAL}"
    done
    
    log "INFO" "${process_name} has finished"
    return 0
}

# Stop area dispatcher
stop_area_dispatcher() {
    local process_name="area_dispatcher"
    
    if ! is_running "${process_name}"; then
        log "WARNING" "${process_name} is not running"
        return 0
    fi
    
    local pid
    pid=$(get_pid "${PROCESSES[$process_name]}")
    log "INFO" "Terminating ${process_name} (PID: ${pid})"
    
    if "${EXEC_DIR}/dispatcher" --areas --terminate 2>/dev/null; then
        sleep 1
        
        if wait_for_termination "${process_name}" 10 1; then
            return 0
        else
            log "ERROR" "Failed to terminate ${process_name}"
            return 1
        fi
    else
        log "ERROR" "Failed to send terminate command to ${process_name}"
        return 1
    fi
}

# Stop base dispatcher
stop_base_dispatcher() {
    local process_name="base_dispatcher"
    
    if ! is_running "${process_name}"; then
        log "WARNING" "${process_name} is not running"
        return 0
    fi
    
    local pid
    pid=$(get_pid "${PROCESSES[$process_name]}")
    log "INFO" "Terminating ${process_name} (PID: ${pid})"
    
    if "${EXEC_DIR}/dispatcher" --osm-base --terminate 2>/dev/null; then
        sleep 1
        
        if wait_for_termination "${process_name}" 10 1; then
            return 0
        else
            log "ERROR" "Failed to terminate ${process_name}"
            return 1
        fi
    else
        log "ERROR" "Failed to send terminate command to ${process_name}"
        return 1
    fi
}

# Main shutdown routine
main() {
    log "INFO" "Shutting down Overpass API components..."
    
    local all_stopped=true
    
    # Stop processes in reverse order
    for process_name in "${SHUTDOWN_ORDER[@]}"; do
        case "${process_name}" in
            fetch_osc)
                if ! stop_fetch_osc; then
                    all_stopped=false
                fi
                ;;
            
            apply_osc)
                if ! stop_apply_osc; then
                    all_stopped=false
                fi
                ;;
            
            area_script)
                if ! stop_area_script; then
                    all_stopped=false
                fi
                ;;
            
            area_updater)
                if ! wait_area_updater; then
                    all_stopped=false
                fi
                ;;
            
            area_dispatcher)
                if ! stop_area_dispatcher; then
                    all_stopped=false
                fi
                ;;
            
            base_dispatcher)
                if ! stop_base_dispatcher; then
                    all_stopped=false
                fi
                ;;
            
            *)
                log "ERROR" "Unknown process: ${process_name}"
                all_stopped=false
                ;;
        esac
        
        # If a critical process failed to stop, abort
        if [[ "${all_stopped}" != "true" ]]; then
            log "ERROR" "Failed to stop ${process_name}, aborting shutdown sequence"
            log "ERROR" "Some processes may still be running"
            exit 1
        fi
    done
    
    # Final verification
    log "INFO" "Verifying all processes have stopped..."
    sleep 1
    
    local still_running=false
    for process_name in base_dispatcher area_dispatcher apply_osc fetch_osc area_script area_updater; do
        if is_running "${process_name}"; then
            local pid
            pid=$(get_pid "${PROCESSES[$process_name]}")
            log "ERROR" "${process_name} is still running (PID: ${pid})"
            still_running=true
        fi
    done
    
    if [[ "${still_running}" == "true" ]]; then
        log "ERROR" "Shutdown incomplete - some processes are still running"
        exit 1
    fi
    
    log "INFO" "All Overpass components stopped successfully"
    exit 0
}

# Run main function
main "$@"
