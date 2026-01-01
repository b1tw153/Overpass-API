#!/usr/bin/env bash

# Robust restore script for Overpass API v0.7.61.4
# Restores database from backup and cleans up leftover files from crashes

set -o pipefail

# Configuration
EXEC_DIR="/opt/overpass/bin"
DB_DIR="/opt/overpass/db"
DIFF_DIR="/opt/overpass/diff"
LOG_DIR="/opt/overpass/log"
BACKUP_SOURCE="/media/all/usb-drive/db"

# Process definitions (for verification)
declare -A PROCESSES=(
    [base_dispatcher]="dispatcher --osm-base"
    [area_dispatcher]="dispatcher --areas"
    [apply_osc]="apply_osc_to_db.sh"
    [fetch_osc]="fetch_osc.sh"
)

REQUIRED_PROCESSES=("base_dispatcher" "area_dispatcher" "apply_osc" "fetch_osc")

# Log file
LOG_FILE="$LOG_DIR/restore.out"
CLEAN_OSC_LOG="$LOG_DIR/clean_osc.out"

# Operation timeouts (seconds)
SHUTDOWN_TIMEOUT=3600   # 1 hour
STARTUP_TIMEOUT=600     # 10 minutes
RSYNC_TIMEOUT=7200      # 2 hours
CLEANUP_TIMEOUT=1800    # 30 minutes

# ============================================================================
# LOGGING
# ============================================================================

log() {
    local level="$1"
    shift
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] ${level}: $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

# ============================================================================
# PROCESS DETECTION
# ============================================================================

get_pid() {
    local process_pattern="$1"
    pgrep -f "${process_pattern}" | head -n 1
}

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

# ============================================================================
# PROCESS CHECK
# ============================================================================

check_any_processes_running() {
    local any_running=false
    
    for process_name in "${REQUIRED_PROCESSES[@]}"; do
        if is_running "${process_name}"; then
            local pid
            pid=$(get_pid "${PROCESSES[$process_name]}")
            log "WARNING" "${process_name} is running (PID: ${pid})"
            any_running=true
        fi
    done
    
    if [[ "${any_running}" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

check_all_processes_running() {
    local all_running=true
    
    for process_name in "${REQUIRED_PROCESSES[@]}"; do
        if ! is_running "${process_name}"; then
            log "ERROR" "${process_name} is not running"
            all_running=false
        else
            local pid
            pid=$(get_pid "${PROCESSES[$process_name]}")
            log "INFO" "${process_name} is running (PID: ${pid})"
        fi
    done
    
    if [[ "${all_running}" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# CONTROLLED SHUTDOWN
# ============================================================================

shutdown_overpass() {
    log "INFO" "Shutting down Overpass for restore..."
    
    if [[ ! -x "${EXEC_DIR}/shutdown.sh" ]]; then
        log_error "shutdown.sh not found or not executable"
        return 1
    fi
    
    # Run shutdown with timeout
    timeout "${SHUTDOWN_TIMEOUT}" "${EXEC_DIR}/shutdown.sh" >> "$LOG_FILE" 2>&1
    local exit_code=$?
    
    if [[ ${exit_code} -eq 0 ]]; then
        log "INFO" "Overpass shutdown completed successfully"
        return 0
    elif [[ ${exit_code} -eq 124 ]]; then
        log_error "Shutdown timed out after ${SHUTDOWN_TIMEOUT} seconds"
        return 1
    else
        log_error "Shutdown failed with exit code ${exit_code}"
        return 1
    fi
}

# ============================================================================
# CONTROLLED STARTUP
# ============================================================================

startup_overpass() {
    log "INFO" "Starting Overpass after restore..."
    
    if [[ ! -x "${EXEC_DIR}/startup.sh" ]]; then
        log_error "startup.sh not found or not executable"
        return 1
    fi
    
    # Run startup with timeout
    timeout "${STARTUP_TIMEOUT}" "${EXEC_DIR}/startup.sh" >> "$LOG_FILE" 2>&1
    local exit_code=$?
    
    if [[ ${exit_code} -eq 0 ]]; then
        log "INFO" "Overpass startup completed successfully"
        return 0
    elif [[ ${exit_code} -eq 124 ]]; then
        log_error "Startup timed out after ${STARTUP_TIMEOUT} seconds"
        return 1
    else
        log_error "Startup failed with exit code ${exit_code}"
        return 1
    fi
}

# ============================================================================
# RESTORE EXECUTION
# ============================================================================

perform_restore() {
    log "INFO" "Starting rsync restore from ${BACKUP_SOURCE}..."
    
    # Verify source directory
    if [[ ! -d "${BACKUP_SOURCE}" ]]; then
        log_error "Backup source directory does not exist: ${BACKUP_SOURCE}"
        return 1
    fi
    
    # Verify source has content
    if [[ -z "$(ls -A "${BACKUP_SOURCE}" 2>/dev/null)" ]]; then
        log_error "Backup source directory is empty: ${BACKUP_SOURCE}"
        return 1
    fi
    
    # Verify destination directory
    if [[ ! -d "${DB_DIR}" ]]; then
        log_error "Database directory does not exist: ${DB_DIR}"
        return 1
    fi
    
    # Verify destination is writable
    if [[ ! -w "${DB_DIR}" ]]; then
        log_error "Database directory is not writable: ${DB_DIR}"
        return 1
    fi
    
    # Perform rsync with timeout
    timeout "${RSYNC_TIMEOUT}" rsync -rav --del "${BACKUP_SOURCE}/" "${DB_DIR}/" >> "$LOG_FILE" 2>&1
    local exit_code=$?
    
    if [[ ${exit_code} -eq 0 ]]; then
        log "INFO" "Restore completed successfully"
        return 0
    elif [[ ${exit_code} -eq 124 ]]; then
        log_error "Restore timed out after ${RSYNC_TIMEOUT} seconds"
        return 1
    else
        log_error "Restore failed with exit code ${exit_code}"
        return 1
    fi
}

# ============================================================================
# CLEANUP OPERATIONS
# ============================================================================

cleanup_diff_directory() {
    log "INFO" "Cleaning up download directory to recover from crashes..."
    
    if [[ ! -x "${EXEC_DIR}/clean_osc.sh" ]]; then
        log_error "clean_osc.sh not found or not executable"
        return 1
    fi
    
    if [[ ! -d "${DIFF_DIR}" ]]; then
        log_error "Diff directory does not exist: ${DIFF_DIR}"
        return 1
    fi
    
    # Run cleanup with --all flag to remove all downloaded files
    timeout "${CLEANUP_TIMEOUT}" "${EXEC_DIR}/clean_osc.sh" --all "${DIFF_DIR}" >> "$CLEAN_OSC_LOG" 2>&1
    local exit_code=$?
    
    if [[ ${exit_code} -eq 0 ]]; then
        log "INFO" "Cleanup completed successfully"
        return 0
    elif [[ ${exit_code} -eq 124 ]]; then
        log_error "Cleanup timed out after ${CLEANUP_TIMEOUT} seconds"
        return 1
    else
        log_error "Cleanup failed with exit code ${exit_code}"
        return 1
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log "INFO" "=========================================="
    log "INFO" "Restore started at $(date '+%Y-%m-%d %H:%M:%S')"
    log "INFO" "=========================================="
    
    # Verify required executables
    for script in shutdown.sh startup.sh clean_osc.sh; do
        if [[ ! -x "${EXEC_DIR}/${script}" ]]; then
            log_error "Required script not found or not executable: ${EXEC_DIR}/${script}"
            exit 1
        fi
    done
    
    # Check if any processes are running
    if check_any_processes_running; then
        log "INFO" "Some Overpass processes are running, shutting down..."
        
        if ! shutdown_overpass; then
            log_error "Failed to shutdown Overpass, aborting restore"
            exit 1
        fi
        
        # Verify all processes stopped
        sleep 2
        if check_any_processes_running; then
            log_error "Some processes still running after shutdown, aborting restore"
            log_error "MANUAL INTERVENTION REQUIRED"
            exit 1
        fi
        
        log "INFO" "All processes stopped successfully"
    else
        log "INFO" "No Overpass processes are running, proceeding with restore"
    fi
    
    # Perform the restore
    if ! perform_restore; then
        log_error "Database restore failed"
        log_error "Overpass remains shut down for manual intervention"
        log_error "DO NOT start Overpass until the database issue is resolved"
        log "INFO" "=========================================="
        log_error "Restore failed at $(date '+%Y-%m-%d %H:%M:%S')"
        log "INFO" "=========================================="
        exit 1
    fi
    
    log "INFO" "Database restored successfully"
    
    # Clean up diff directory (critical for proper restart after restore)
    if ! cleanup_diff_directory; then
        log_error "Cleanup failed - this must be resolved before starting Overpass"
        log_error "Overpass remains shut down for manual intervention"
        log_error "Please manually clean up ${DIFF_DIR} or run: ${EXEC_DIR}/clean_osc.sh --all ${DIFF_DIR}"
        log "INFO" "=========================================="
        log_error "Restore incomplete at $(date '+%Y-%m-%d %H:%M:%S')"
        log "INFO" "=========================================="
        exit 1
    fi
    
    log "INFO" "Cleanup completed, ready to start Overpass"
    
    # Start Overpass after successful restore and cleanup
    log "INFO" "Starting Overpass..."
    if ! startup_overpass; then
        log_error "Failed to start Overpass after restore"
        log_error "Database has been restored but Overpass is not running"
        log_error "MANUAL INTERVENTION REQUIRED"
        log_error "Try running: ${EXEC_DIR}/startup.sh"
        log "INFO" "=========================================="
        log_error "Restore completed but startup failed at $(date '+%Y-%m-%d %H:%M:%S')"
        log "INFO" "=========================================="
        exit 1
    fi
    
    # Verify processes started
    sleep 5
    log "INFO" "Verifying Overpass started successfully..."
    if ! check_all_processes_running; then
        log_error "Overpass did not start properly after restore"
        log_error "Some processes are not running"
        log_error "MANUAL INTERVENTION REQUIRED"
        log "INFO" "=========================================="
        log_error "Restore completed but verification failed at $(date '+%Y-%m-%d %H:%M:%S')"
        log "INFO" "=========================================="
        exit 1
    fi
    
    log "INFO" "=========================================="
    log "INFO" "Restore completed successfully at $(date '+%Y-%m-%d %H:%M:%S')"
    log "INFO" "All Overpass processes are running normally"
    log "INFO" "=========================================="
    exit 0
}

# Run main function
main "$@"
