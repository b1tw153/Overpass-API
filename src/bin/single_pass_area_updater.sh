#!/usr/bin/env bash

# Robust area update script for Overpass API v0.7.61.4
# Performs a single-pass area update with proper error handling

set -o pipefail

# Configuration
EXEC_DIR="/opt/overpass/bin"
DB_DIR="/opt/overpass/db"
LOG_DIR="/opt/overpass/log"

# Files
RULES_FILE="$DB_DIR/rules/areas.osm3s"
LOG_FILE="$LOG_DIR/area_update.out"

# Timeout (4 hours for large area updates)
UPDATE_TIMEOUT=14400

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
# VALIDATION
# ============================================================================

validate_environment() {
    # Check executable exists
    if [[ ! -x "${EXEC_DIR}/osm3s_query" ]]; then
        log_error "osm3s_query not found or not executable: ${EXEC_DIR}/osm3s_query"
        return 1
    fi
    
    # Check rules file exists
    if [[ ! -f "${RULES_FILE}" ]]; then
        log_error "Rules file not found: ${RULES_FILE}"
        return 1
    fi
    
    # Check rules file is readable
    if [[ ! -r "${RULES_FILE}" ]]; then
        log_error "Rules file is not readable: ${RULES_FILE}"
        return 1
    fi
    
    # Check log directory exists and is writable
    if [[ ! -d "${LOG_DIR}" ]]; then
        log_error "Log directory does not exist: ${LOG_DIR}"
        return 1
    fi
    
    if [[ ! -w "${LOG_DIR}" ]]; then
        log_error "Log directory is not writable: ${LOG_DIR}"
        return 1
    fi
    
    return 0
}

# ============================================================================
# AREA UPDATE
# ============================================================================

perform_area_update() {
    log "INFO" "Starting area update with rules from ${RULES_FILE}"
    
    # Change to execution directory
    cd "${EXEC_DIR}" || {
        log_error "Failed to change to execution directory: ${EXEC_DIR}"
        return 1
    }
    
    # Run area update with timeout, nice, and ionice
    local start_time
    start_time=$(date +%s)
    
    timeout "${UPDATE_TIMEOUT}" \
        ionice -c 3 nice -n 19 \
        "${EXEC_DIR}/osm3s_query" --progress --rules \
        < "${RULES_FILE}" >> "${LOG_FILE}" 2>&1
    
    local exit_code=$?
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Format duration as hours:minutes:seconds
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    local duration_formatted
    printf -v duration_formatted "%02d:%02d:%02d" ${hours} ${minutes} ${seconds}
    
    cd - > /dev/null || true
    
    if [[ ${exit_code} -eq 0 ]]; then
        log "INFO" "Area update completed successfully (duration: ${duration_formatted})"
        return 0
    elif [[ ${exit_code} -eq 124 ]]; then
        log_error "Area update timed out after ${UPDATE_TIMEOUT} seconds"
        return 1
    else
        log_error "Area update failed with exit code ${exit_code} (duration: ${duration_formatted})"
        return 1
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log "INFO" "=========================================="
    log "INFO" "Area update started"
    log "INFO" "=========================================="
    
    # Validate environment
    if ! validate_environment; then
        log_error "Environment validation failed"
        exit 1
    fi
    
    # Perform area update
    if perform_area_update; then
        log "INFO" "=========================================="
        log "INFO" "Area update finished successfully"
        log "INFO" "=========================================="
        exit 0
    else
        log_error "=========================================="
        log_error "Area update failed"
        log_error "=========================================="
        exit 1
    fi
}

# Run main function
main "$@"
