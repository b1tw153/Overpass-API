#!/usr/bin/env bash

# Robust backup script for Overpass API v0.7.61.4
# Performs safe backup with process verification and error handling

set -o pipefail

# Configuration
EXEC_DIR="/opt/overpass/bin"
DB_DIR="/opt/overpass/db"
DIFF_DIR="/opt/overpass/diff"
LOG_DIR="/opt/overpass/log"
BACKUP_DEST="/media/all/usb-drive/db"

# Process definitions (must match startup.sh and shutdown.sh)
declare -A PROCESSES=(
    [base_dispatcher]="dispatcher --osm-base"
    [area_dispatcher]="dispatcher --areas"
    [apply_osc]="apply_osc_to_db.sh"
    [fetch_osc]="fetch_osc.sh"
)

# Required processes for backup
REQUIRED_PROCESSES=("base_dispatcher" "area_dispatcher" "apply_osc" "fetch_osc")

# Log file
LOG_FILE="$LOG_DIR/backup.out"
CLEAN_OSC_LOG="$LOG_DIR/clean_osc.out"

# Backup timeout (seconds)
SHUTDOWN_TIMEOUT=3600   # 1 hour
STARTUP_TIMEOUT=600     # 10 minutes
RSYNC_TIMEOUT=7200      # 2 hours

# ============================================================================
# LOGGING
# ============================================================================

log() {
    local level="$1"
    shift
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] ${level}: $*" | tee -a "$LOG_FILE"
}

log_error() {
    local level="ERROR"
    shift
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] ${level}: $*" | tee -a "$LOG_FILE" >&2
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
# HEALTH CHECK
# ============================================================================

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
    log "INFO" "Shutting down Overpass for backup..."
    
    if [[ ! -x "${EXEC_DIR}/shutdown.sh" ]]; then
        log "ERROR" "shutdown.sh not found or not executable"
        return 1
    fi
    
    # Run shutdown with timeout
    timeout "${SHUTDOWN_TIMEOUT}" "${EXEC_DIR}/shutdown.sh" >> "$LOG_FILE" 2>&1
    local exit_code=$?
    
    if [[ ${exit_code} -eq 0 ]]; then
        log "INFO" "Overpass shutdown completed successfully"
        return 0
    elif [[ ${exit_code} -eq 124 ]]; then
        log "ERROR" "Shutdown timed out after ${SHUTDOWN_TIMEOUT} seconds"
        return 1
    else
        log "ERROR" "Shutdown failed with exit code ${exit_code}"
        return 1
    fi
}

# ============================================================================
# CONTROLLED STARTUP
# ============================================================================

startup_overpass() {
    log "INFO" "Starting Overpass after backup..."
    
    if [[ ! -x "${EXEC_DIR}/startup.sh" ]]; then
        log "ERROR" "startup.sh not found or not executable"
        return 1
    fi
    
    # Run startup with timeout
    timeout "${STARTUP_TIMEOUT}" "${EXEC_DIR}/startup.sh" >> "$LOG_FILE" 2>&1
    local exit_code=$?
    
    if [[ ${exit_code} -eq 0 ]]; then
        log "INFO" "Overpass startup completed successfully"
        return 0
    elif [[ ${exit_code} -eq 124 ]]; then
        log "ERROR" "Startup timed out after ${STARTUP_TIMEOUT} seconds"
        return 1
    else
        log "ERROR" "Startup failed with exit code ${exit_code}"
        return 1
    fi
}

# ============================================================================
# BACKUP EXECUTION
# ============================================================================

perform_backup() {
    log "INFO" "Starting rsync backup to ${BACKUP_DEST}..."
    
    # Verify source directory
    if [[ ! -d "${DB_DIR}" ]]; then
        log "ERROR" "Source directory does not exist: ${DB_DIR}"
        return 1
    fi
    
    # Create backup destination if needed
    mkdir -p "${BACKUP_DEST}" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Cannot create backup destination: ${BACKUP_DEST}"
        return 1
    fi
    
    # Verify destination is writable
    if [[ ! -w "${BACKUP_DEST}" ]]; then
        log "ERROR" "Backup destination is not writable: ${BACKUP_DEST}"
        return 1
    fi
    
    # Perform rsync with timeout
    timeout "${RSYNC_TIMEOUT}" rsync -rav --del "${DB_DIR}/" "${BACKUP_DEST}/" >> "$LOG_FILE" 2>&1
    local exit_code=$?
    
    if [[ ${exit_code} -eq 0 ]]; then
        log "INFO" "Backup completed successfully"
        return 0
    elif [[ ${exit_code} -eq 124 ]]; then
        log "ERROR" "Backup timed out after ${RSYNC_TIMEOUT} seconds"
        return 1
    else
        log "ERROR" "Backup failed with exit code ${exit_code}"
        return 1
    fi
}

# ============================================================================
# CLEANUP OLD FILES
# ============================================================================

cleanup_old_files() {
    log "INFO" "Cleaning up old .osc.gz and .state.txt files..."
    
    if [[ ! -x "${EXEC_DIR}/clean_osc.sh" ]]; then
        log "WARNING" "clean_osc.sh not found or not executable, skipping cleanup"
        return 0
    fi
    
    "${EXEC_DIR}/clean_osc.sh" "$DB_DIR" "$DIFF_DIR" >> "$CLEAN_OSC_LOG" 2>&1
    local exit_code=$?
    
    if [[ ${exit_code} -eq 0 ]]; then
        log "INFO" "Cleanup completed successfully"
        return 0
    else
        log "WARNING" "Cleanup failed with exit code ${exit_code} (non-critical)"
        return 0  # Non-critical failure
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log "INFO" "=========================================="
    log "INFO" "Backup started at $(date '+%Y-%m-%d %H:%M:%S')"
    log "INFO" "=========================================="
    
    # Verify required executables
    for script in shutdown.sh startup.sh; do
        if [[ ! -x "${EXEC_DIR}/${script}" ]]; then
            log "ERROR" "Required script not found or not executable: ${EXEC_DIR}/${script}"
            exit 1
        fi
    done
    
    # Check if all required processes are running
    log "INFO" "Verifying Overpass is running and healthy..."
    if ! check_all_processes_running; then
        log "ERROR" "Overpass is not running properly"
        log "INFO" "Attempting emergency shutdown to clean up..."
        shutdown_overpass || true
        exit 1
    fi
    
    log "INFO" "All Overpass processes are running and healthy"
    
    # Shutdown Overpass
    if ! shutdown_overpass; then
        log "ERROR" "Failed to shutdown Overpass, aborting backup"
        exit 1
    fi
    
    # Verify all processes stopped
    sleep 2
    local still_running=false
    for process_name in "${REQUIRED_PROCESSES[@]}"; do
        if is_running "${process_name}"; then
            log "ERROR" "${process_name} is still running after shutdown"
            still_running=true
        fi
    done
    
    if [[ "${still_running}" == "true" ]]; then
        log "ERROR" "Some processes still running after shutdown, aborting backup"
        log "WARNING" "Manual intervention may be required"
        exit 1
    fi
    
    log "INFO" "All processes stopped, database is safe to backup"
    
    # Perform the backup
    backup_success=false
    if perform_backup; then
        backup_success=true
        log "INFO" "Backup completed successfully"
    else
        log "ERROR" "Backup failed"
    fi
    
    # Clean up old OSC files (non-critical)
    cleanup_old_files
    
    # Always try to restart Overpass
    log "INFO" "Restarting Overpass..."
    if ! startup_overpass; then
        log "ERROR" "Failed to restart Overpass after backup"
        log "ERROR" "MANUAL INTERVENTION REQUIRED - Overpass is not running!"
        exit 1
    fi
    
    # Verify processes started
    sleep 5
    log "INFO" "Verifying Overpass restarted successfully..."
    if ! check_all_processes_running; then
        log "ERROR" "Overpass did not restart properly after backup"
        log "ERROR" "MANUAL INTERVENTION REQUIRED - Some processes are not running!"
        exit 1
    fi
    
    log "INFO" "=========================================="
    log "INFO" "Backup finished at $(date '+%Y-%m-%d %H:%M:%S')"
    log "INFO" "=========================================="
    
    if [[ "${backup_success}" == "true" ]]; then
        log "INFO" "Backup completed successfully, Overpass is running normally"
        exit 0
    else
        log "ERROR" "Backup failed, but Overpass has been restarted"
        exit 1
    fi
}

# Run main function
main "$@"
