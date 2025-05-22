#!/bin/bash

# --- Configuration ---
# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check if config.sh exists and source it
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
else
    echo "Error: Configuration file ${CONFIG_FILE} not found."
    echo "Please copy config.example.sh to config.sh and update the values."
    exit 1
fi

# Parse command line arguments
FORCE_REBUILD=false
for arg in "$@"; do
    case $arg in
        --force)
            FORCE_REBUILD=true
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--force]"
            echo "  --force: Force rebuild and service restart even if no Git changes are detected"
            exit 1
            ;;
    esac
done

# --- Script Logic ---

# Get the current date for log file naming
CURRENT_DATE=$(date +"%Y-%m-%d")
LOG_FILE="${LOG_DIR}/${LOG_BASE_NAME}_${CURRENT_DATE}.log"
CURRENT_BACKUP_FILE="" # Variable to store the name of the backup made in this run

# Function to log messages with a timestamp
log_message() {
    # Ensure log directory exists before trying to write the first message.
    # This is called before any logging operation.
    if ! mkdir -p "${LOG_DIR}" >/dev/null 2>&1; then
        # If log directory creation fails, echo to stderr as we can't use LOG_FILE
        echo "$(date '+%Y-%m-%d %H:%M:%S') - CRITICAL: Log directory ${LOG_DIR} could not be created. Logging to this file will fail. Exiting." >&2
        exit 1; # Exit if we can't even create the log directory
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
}

# --- Log Cleanup (runs after LOG_DIR is ensured) ---
# Explicitly ensure LOG_DIR exists before cleanup.
if ! mkdir -p "${LOG_DIR}" >/dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - CRITICAL: Log directory ${LOG_DIR} for cleanup could not be created. Exiting." >&2
    exit 1;
fi

# Now that LOG_DIR is confirmed, we can use log_message for cleanup logs.
log_message "--- Starting log cleanup (logs older than 90 days in ${LOG_DIR}) ---"
# Find and delete old log files. Capture names of deleted files.
# Using -print before -delete to capture names.
deleted_logs_output=$(find "${LOG_DIR}" -name "${LOG_BASE_NAME}_*.log" -type f -mtime +90 -print -delete 2>&1)
find_exit_status=$? # Capture exit status of find

if [ ${find_exit_status} -eq 0 ]; then
    if [ -n "$deleted_logs_output" ]; then
        log_message "Successfully deleted old log files:"
        echo "$deleted_logs_output" | while read -r line; do
            log_message "  - $line"
        done
    else
        log_message "No old log files to delete."
    fi
else
    log_message "WARNING: Failed to clean up old log files. Error: $deleted_logs_output"
fi

log_message "--- Starting Go project update script ---"

# Validate required variables
if [ -z "${REPO_PATH}" ]; then
    log_message "ERROR: REPO_PATH is not set in config.sh"
    exit 1
fi

if [ -z "${PROJECT_DIR}" ]; then
    log_message "ERROR: PROJECT_DIR is not set in config.sh"
    exit 1
fi

if [ -z "${GO_EXECUTABLE_NAME}" ]; then
    log_message "ERROR: GO_EXECUTABLE_NAME is not set in config.sh"
    exit 1
fi

if [ -z "${GO_EXECUTABLE_DEST}" ]; then
    log_message "ERROR: GO_EXECUTABLE_DEST is not set in config.sh"
    exit 1
fi

if [ -z "${RC_SERVICE_NAME}" ]; then
    log_message "ERROR: RC_SERVICE_NAME is not set in config.sh"
    exit 1
fi

# Check if repository directory exists
if [ ! -d "${REPO_PATH}" ]; then
    log_message "ERROR: Repository directory ${REPO_PATH} does not exist."
    log_message "Please make sure the directory exists and contains a valid Git repository."
    exit 1
fi

# Change to the repository directory for Git operations
cd "${REPO_PATH}" || {
    log_message "ERROR: Failed to change to repository directory ${REPO_PATH}."
    exit 1
}

log_message "Changed to repository directory: ${REPO_PATH}"

# Function to handle Git's dubious ownership error
handle_dubious_ownership() {
    local git_error=$1
    local repo_path
    
    # Extract the repository path from the error message
    if [[ "$git_error" =~ detected[[:space:]]dubious[[:space:]]ownership[[:space:]]in[[:space:]]repository[[:space:]]at[[:space:]][\'\"](.*)[\'\"] ]]; then
        repo_path="${BASH_REMATCH[1]}"
        log_message "Detected dubious ownership error for repository: $repo_path"
        
        # Add the repository to safe.directory
        if [ -n "${BUILD_USER}" ]; then
            log_message "Adding repository to safe.directory for user ${BUILD_USER}..."
            ${SUDO_CMD} -n -u ${BUILD_USER} ${GIT_CMD} config --global --add safe.directory "$repo_path"
        else
            log_message "Adding repository to safe.directory..."
            ${GIT_CMD} config --global --add safe.directory "$repo_path"
        fi
        
        return 0 # Success
    fi
    
    return 1 # Failed to extract repo path
}

# Function to attempt git pull without sudo
attempt_direct_pull() {
    log_message "Attempting direct git pull without sudo..."
    ${GIT_CMD} pull 2>&1
    return $?
}

# Get the current commit hash before pull
if [ -n "${BUILD_USER}" ]; then
    log_message "Getting current commit hash as user: ${BUILD_USER}"
    log_message "Debug: SUDO_CMD=${SUDO_CMD}, BUILD_USER=${BUILD_USER}, GIT_CMD=${GIT_CMD}"
    
    # Try different sudo approaches
    log_message "Debug: Trying approach 1: ${SUDO_CMD} -n -u ${BUILD_USER} ${GIT_CMD} rev-parse HEAD"
    old_commit_output=$(${SUDO_CMD} -n -u ${BUILD_USER} ${GIT_CMD} rev-parse HEAD 2>&1)
    old_commit_status=$?
    
    if [ ${old_commit_status} -ne 0 ] && [[ "${old_commit_output}" == *"a password is required"* ]]; then
        log_message "Debug: First approach failed, trying approach 2: ${SUDO_CMD} -n -u ${BUILD_USER} -- ${GIT_CMD} rev-parse HEAD"
        old_commit_output=$(${SUDO_CMD} -n -u ${BUILD_USER} -- ${GIT_CMD} rev-parse HEAD 2>&1)
        old_commit_status=$?
    fi
    log_message "Debug: Command exit status: ${old_commit_status}"
    log_message "Debug: Command output: ${old_commit_output}"
    
    # Handle dubious ownership error if it occurs
    if [ ${old_commit_status} -ne 0 ] && [[ "${old_commit_output}" == *"dubious ownership"* ]]; then
        if handle_dubious_ownership "${old_commit_output}"; then
            log_message "Retrying git rev-parse after fixing dubious ownership..."
            old_commit_output=$(${SUDO_CMD} -n -u ${BUILD_USER} ${GIT_CMD} rev-parse HEAD 2>&1)
            old_commit_status=$?
            
            if [ ${old_commit_status} -ne 0 ] && [[ "${old_commit_output}" == *"a password is required"* ]]; then
                log_message "Debug: First approach failed, trying approach 2: ${SUDO_CMD} -n -u ${BUILD_USER} -- ${GIT_CMD} rev-parse HEAD"
                old_commit_output=$(${SUDO_CMD} -n -u ${BUILD_USER} -- ${GIT_CMD} rev-parse HEAD 2>&1)
                old_commit_status=$?
            fi
        fi
    fi
else
    log_message "Getting current commit hash"
    old_commit_output=$(${GIT_CMD} rev-parse HEAD 2>&1)
    old_commit_status=$?
    
    # Handle dubious ownership error if it occurs
    if [ ${old_commit_status} -ne 0 ] && [[ "${old_commit_output}" == *"dubious ownership"* ]]; then
        if handle_dubious_ownership "${old_commit_output}"; then
            log_message "Retrying git rev-parse after fixing dubious ownership..."
            old_commit_output=$(${GIT_CMD} rev-parse HEAD 2>&1)
            old_commit_status=$?
        fi
    fi
fi

if [ ${old_commit_status} -ne 0 ]; then
    log_message "ERROR: Failed to get current commit hash. Output: ${old_commit_output}"
    exit 1
fi

old_commit=${old_commit_output}
log_message "Current commit hash: ${old_commit}"

# Pull the latest changes
log_message "Pulling latest changes from git repository..."

# Try with sudo first if BUILD_USER is specified
if [ -n "${BUILD_USER}" ]; then
    # Try with sudo first
    log_message "Pulling as user: ${BUILD_USER}"
    git_pull_output=$(${SUDO_CMD} -n -u ${BUILD_USER} ${GIT_CMD} pull 2>&1)
    git_pull_status=$?
    
    if [ ${git_pull_status} -ne 0 ] && [[ "${git_pull_output}" == *"a password is required"* ]]; then
        log_message "Debug: First git pull approach failed, trying approach 2: ${SUDO_CMD} -n -u ${BUILD_USER} -- ${GIT_CMD} pull"
        git_pull_output=$(${SUDO_CMD} -n -u ${BUILD_USER} -- ${GIT_CMD} pull 2>&1)
        git_pull_status=$?
    fi
    
    # Handle dubious ownership error if it occurs
    if [ ${git_pull_status} -ne 0 ] && [[ "${git_pull_output}" == *"dubious ownership"* ]]; then
        if handle_dubious_ownership "${git_pull_output}"; then
            log_message "Retrying git pull after fixing dubious ownership..."
            git_pull_output=$(${SUDO_CMD} -n -u ${BUILD_USER} ${GIT_CMD} pull 2>&1)
            git_pull_status=$?
            
            if [ ${git_pull_status} -ne 0 ] && [[ "${git_pull_output}" == *"a password is required"* ]]; then
                log_message "Debug: First git pull retry approach failed, trying approach 2: ${SUDO_CMD} -n -u ${BUILD_USER} -- ${GIT_CMD} pull"
                git_pull_output=$(${SUDO_CMD} -n -u ${BUILD_USER} -- ${GIT_CMD} pull 2>&1)
                git_pull_status=$?
            fi
        fi
    fi
    
    # If sudo fails with authentication error and this is likely a public repo, try direct pull
    if [ ${git_pull_status} -ne 0 ] && [[ "${git_pull_output}" == *"sudo: a password is required"* ]]; then
        log_message "sudo authentication required. Trying direct git pull as this might be a public repository..."
        git_pull_output=$(attempt_direct_pull)
        git_pull_status=$?
    fi
else
    # Direct pull if no BUILD_USER
    git_pull_output=$(${GIT_CMD} pull 2>&1)
    git_pull_status=$?
    
    # Handle dubious ownership error if it occurs
    if [ ${git_pull_status} -ne 0 ] && [[ "${git_pull_output}" == *"dubious ownership"* ]]; then
        if handle_dubious_ownership "${git_pull_output}"; then
            log_message "Retrying git pull after fixing dubious ownership..."
            git_pull_output=$(${GIT_CMD} pull 2>&1)
            git_pull_status=$?
        fi
    fi
fi

if [ ${git_pull_status} -ne 0 ]; then
    log_message "ERROR: Failed to pull latest changes. Output: ${git_pull_output}"
    exit 1
fi

log_message "Git pull output: ${git_pull_output}"

# Get the new commit hash after pull
if [ -n "${BUILD_USER}" ]; then
    new_commit_output=$(${SUDO_CMD} -n -u ${BUILD_USER} ${GIT_CMD} rev-parse HEAD 2>&1)
    new_commit_status=$?
    
    if [ ${new_commit_status} -ne 0 ] && [[ "${new_commit_output}" == *"a password is required"* ]]; then
        log_message "Debug: First new commit hash approach failed, trying approach 2: ${SUDO_CMD} -n -u ${BUILD_USER} -- ${GIT_CMD} rev-parse HEAD"
        new_commit_output=$(${SUDO_CMD} -n -u ${BUILD_USER} -- ${GIT_CMD} rev-parse HEAD 2>&1)
        new_commit_status=$?
    fi
else
    new_commit_output=$(${GIT_CMD} rev-parse HEAD 2>&1)
    new_commit_status=$?
fi

if [ ${new_commit_status} -ne 0 ]; then
    log_message "ERROR: Failed to get new commit hash. Output: ${new_commit_output}"
    exit 1
fi

new_commit=${new_commit_output}
log_message "New commit hash: ${new_commit}"

# Check if there are any changes
if [ "${old_commit}" = "${new_commit}" ] && [[ "${git_pull_output}" != *"Already up to date"* ]]; then
    log_message "WARNING: Commit hash unchanged but git pull did not report 'Already up to date'."
    log_message "This could indicate a non-fast-forward update or other git operation."
    log_message "Proceeding with build to be safe."
elif [ "${old_commit}" = "${new_commit}" ] && [ "${FORCE_REBUILD}" = false ]; then
    log_message "No changes detected and --force not specified. Exiting."
    exit 0
elif [ "${old_commit}" = "${new_commit}" ] && [ "${FORCE_REBUILD}" = true ]; then
    log_message "No changes detected but --force specified. Proceeding with build anyway."
else
    log_message "Changes detected. Proceeding with build."
fi

# --- Change to the project directory for building ---
if [ "${REPO_PATH}" != "${PROJECT_DIR}" ]; then
    cd "${PROJECT_DIR}" || {
        log_message "ERROR: Failed to change to project directory ${PROJECT_DIR}."
        exit 1
    }
    log_message "Changed to project directory: ${PROJECT_DIR}"
fi

# --- Build Operations ---

# Set up GOCACHE and GOMODCACHE in the project directory if BUILD_USER is specified
# This ensures the build user has write access to these directories
if [ -n "${BUILD_USER}" ]; then
    # Function to attempt direct mkdir without sudo
    attempt_direct_mkdir() {
        local dir=$1
        log_message "Attempting direct mkdir for ${dir} without sudo..."
        mkdir -p "${dir}" 2>&1
        return $?
    }
    
    # Create GOCACHE directory
    GOCACHE_DIR="${PROJECT_DIR}/.gocache"
    log_message "Setting up GOCACHE directory: ${GOCACHE_DIR}"
    mkdir_gocache_output=$(${SUDO_CMD} -n mkdir -p "${GOCACHE_DIR}" 2>&1)
    mkdir_gocache_status=$?
    
    if [ ${mkdir_gocache_status} -ne 0 ]; then
        if [[ "${mkdir_gocache_output}" == *"sudo: a password is required"* ]]; then
            log_message "sudo authentication required. Trying direct mkdir for GOCACHE_DIR..."
            mkdir_gocache_output=$(attempt_direct_mkdir "${GOCACHE_DIR}")
            mkdir_gocache_status=$?
        fi
        
        if [ ${mkdir_gocache_status} -ne 0 ]; then
            log_message "WARNING: Failed to create GOCACHE directory. Build may fail. Output: ${mkdir_gocache_output}"
        fi
    fi
    
    # Create GOMODCACHE directory
    GOMODCACHE_DIR="${PROJECT_DIR}/.gomodcache"
    log_message "Setting up GOMODCACHE directory: ${GOMODCACHE_DIR}"
    mkdir_gomodcache_output=$(${SUDO_CMD} -n mkdir -p "${GOMODCACHE_DIR}" 2>&1)
    mkdir_gomodcache_status=$?
    
    if [ ${mkdir_gomodcache_status} -ne 0 ]; then
        if [[ "${mkdir_gomodcache_output}" == *"sudo: a password is required"* ]]; then
            log_message "sudo authentication required. Trying direct mkdir for GOMODCACHE_DIR..."
            mkdir_gomodcache_output=$(attempt_direct_mkdir "${GOMODCACHE_DIR}")
            mkdir_gomodcache_status=$?
        fi
        
        if [ ${mkdir_gomodcache_status} -ne 0 ]; then
            log_message "WARNING: Failed to create GOMODCACHE directory. Build may fail. Output: ${mkdir_gomodcache_output}"
        fi
    fi
    
    # Set environment variables for the build
    export GOCACHE="${GOCACHE_DIR}"
    export GOMODCACHE="${GOMODCACHE_DIR}"
    log_message "Set GOCACHE=${GOCACHE} and GOMODCACHE=${GOMODCACHE}"
    
    # Try with sudo first
    log_message "Building as user: ${BUILD_USER} with custom Go cache directories"
    build_output=$(${SUDO_CMD} -n -u ${BUILD_USER} env GOCACHE="${GOCACHE_DIR}" GOMODCACHE="${GOMODCACHE_DIR}" ${GO_CMD} build -o "${PROJECT_DIR}/${GO_EXECUTABLE_NAME}.tmp" . 2>&1)
    build_status=$?
    
    if [ ${build_status} -ne 0 ] && [[ "${build_output}" == *"a password is required"* ]]; then
        log_message "Debug: First build approach failed, trying approach 2: ${SUDO_CMD} -n -u ${BUILD_USER} -- env GOCACHE=\"${GOCACHE_DIR}\" GOMODCACHE=\"${GOMODCACHE_DIR}\" ${GO_CMD} build -o \"${PROJECT_DIR}/${GO_EXECUTABLE_NAME}.tmp\" ."
        build_output=$(${SUDO_CMD} -n -u ${BUILD_USER} -- env GOCACHE="${GOCACHE_DIR}" GOMODCACHE="${GOMODCACHE_DIR}" ${GO_CMD} build -o "${PROJECT_DIR}/${GO_EXECUTABLE_NAME}.tmp" . 2>&1)
        build_status=$?
    fi
    
    # If sudo fails with authentication error, try direct build
    if [ ${build_status} -ne 0 ] && [[ "${build_output}" == *"sudo: a password is required"* ]]; then
        log_message "sudo authentication required. Trying direct go build..."
        build_output=$(${GO_CMD} build -o "${PROJECT_DIR}/${GO_EXECUTABLE_NAME}.tmp" . 2>&1)
        build_status=$?
    fi
else
    # Direct build if no BUILD_USER
    log_message "Building Go executable..."
    build_output=$(${GO_CMD} build -o "${PROJECT_DIR}/${GO_EXECUTABLE_NAME}.tmp" . 2>&1)
    build_status=$?
fi

if [ ${build_status} -ne 0 ]; then
    log_message "ERROR: Build failed. Output: ${build_output}"
    # Clean up the temporary file if it exists
    if [ -f "${PROJECT_DIR}/${GO_EXECUTABLE_NAME}.tmp" ]; then
        rm -f "${PROJECT_DIR}/${GO_EXECUTABLE_NAME}.tmp"
    fi
    exit 1
fi

log_message "Build successful."

# Function to attempt direct file operations without sudo
attempt_direct_file_op() {
    local op=$1 # "mv" or "rm"
    local src=$2
    local dest=$3 # Only for mv
    
    log_message "Attempting direct ${op} without sudo: ${src} to ${dest}..."
    if [ "${op}" = "mv" ]; then
        mv "${src}" "${dest}" 2>&1
    elif [ "${op}" = "rm" ]; then
        rm -f "${src}" 2>&1
    fi
    return $?
}

# Create a backup of the current executable
if [ -f "${GO_EXECUTABLE_DEST}" ]; then
    TIMESTAMP=$(date '+%Y%m%d%H%M%S')
    BACKUP_FILE="${GO_EXECUTABLE_DEST}.bak_${TIMESTAMP}"
    CURRENT_BACKUP_FILE="${BACKUP_FILE}" # Store for potential cleanup later
    
    log_message "Creating backup of current executable to ${BACKUP_FILE}..."
    mv_backup_output=$(${SUDO_CMD} -n mv "${GO_EXECUTABLE_DEST}" "${BACKUP_FILE}" 2>&1)
    mv_backup_status=$?
    
    # If sudo fails with authentication error, try direct mv
    if [ ${mv_backup_status} -ne 0 ] && [[ "${mv_backup_output}" == *"sudo: a password is required"* ]]; then
        log_message "sudo authentication required. Trying direct mv for backup..."
        mv_backup_output=$(attempt_direct_file_op "mv" "${GO_EXECUTABLE_DEST}" "${BACKUP_FILE}")
        mv_backup_status=$?
    fi
    
    if [ ${mv_backup_status} -ne 0 ]; then
        log_message "ERROR: Failed to create backup of current executable. Output: ${mv_backup_output}"
        # Clean up the temporary file
        rm -f "${PROJECT_DIR}/${GO_EXECUTABLE_NAME}.tmp"
        exit 1
    fi
    
    log_message "Backup created successfully."
else
    log_message "No existing executable to backup at ${GO_EXECUTABLE_DEST}."
fi

# Move the new executable to the destination
log_message "Moving new executable to ${GO_EXECUTABLE_DEST}..."
mv_new_output=$(${SUDO_CMD} -n mv "${PROJECT_DIR}/${GO_EXECUTABLE_NAME}.tmp" "${GO_EXECUTABLE_DEST}" 2>&1)
mv_new_status=$?

# If sudo fails with authentication error, try direct mv
if [ ${mv_new_status} -ne 0 ] && [[ "${mv_new_output}" == *"sudo: a password is required"* ]]; then
    log_message "sudo authentication required. Trying direct mv for new executable..."
    mv_new_output=$(attempt_direct_file_op "mv" "${PROJECT_DIR}/${GO_EXECUTABLE_NAME}.tmp" "${GO_EXECUTABLE_DEST}")
    mv_new_status=$?
fi

if [ ${mv_new_status} -ne 0 ]; then
    log_message "ERROR: Failed to move new executable to destination. Output: ${mv_new_output}"
    
    # If we have a backup, try to restore it
    if [ -n "${CURRENT_BACKUP_FILE}" ] && [ -f "${CURRENT_BACKUP_FILE}" ]; then
        log_message "Attempting to restore backup from ${CURRENT_BACKUP_FILE}..."
        restore_output=$(${SUDO_CMD} -n mv "${CURRENT_BACKUP_FILE}" "${GO_EXECUTABLE_DEST}" 2>&1)
        restore_status=$?
        
        # If sudo fails with authentication error, try direct mv
        if [ ${restore_status} -ne 0 ] && [[ "${restore_output}" == *"sudo: a password is required"* ]]; then
            log_message "sudo authentication required. Trying direct mv for restore..."
            restore_output=$(attempt_direct_file_op "mv" "${CURRENT_BACKUP_FILE}" "${GO_EXECUTABLE_DEST}")
            restore_status=$?
        fi
        
        if [ ${restore_status} -eq 0 ]; then
            log_message "Successfully restored backup."
        else
            log_message "WARNING: Failed to restore backup. Output: ${restore_output}"
        fi
    fi
    
    exit 1
fi

log_message "New executable moved to destination successfully."

# Function to attempt direct service restart without sudo
attempt_direct_service_restart() {
    log_message "Attempting direct service restart without sudo..."
    systemctl restart "${RC_SERVICE_NAME}" 2>&1
    return $?
}

# Restart the systemd service
log_message "Attempting to restart systemd service ${RC_SERVICE_NAME}..."
restart_output=$(${SUDO_CMD} -n systemctl restart "${RC_SERVICE_NAME}" 2>&1)
restart_status=$?

# If sudo fails with authentication error, try direct restart
if [ ${restart_status} -ne 0 ] && [[ "${restart_output}" == *"sudo: a password is required"* ]]; then
    log_message "sudo authentication required. Trying direct service restart..."
    restart_output=$(attempt_direct_service_restart)
    restart_status=$?
fi

if [ ${restart_status} -ne 0 ]; then
    log_message "ERROR: Failed to restart systemd service ${RC_SERVICE_NAME} with status ${restart_status}."
    log_message "Restart output: ${restart_output}"
    log_message "Attempting to roll back to previous executable..."
    
    if [ -n "${CURRENT_BACKUP_FILE}" ] && [ -f "${CURRENT_BACKUP_FILE}" ]; then
        log_message "Rolling back to backup from ${CURRENT_BACKUP_FILE}..."
        rollback_output=$(${SUDO_CMD} -n mv "${CURRENT_BACKUP_FILE}" "${GO_EXECUTABLE_DEST}" 2>&1)
        rollback_status=$?
        
        # If sudo fails with authentication error, try direct mv
        if [ ${rollback_status} -ne 0 ] && [[ "${rollback_output}" == *"sudo: a password is required"* ]]; then
            log_message "sudo authentication required. Trying direct mv for rollback..."
            rollback_output=$(attempt_direct_file_op "mv" "${CURRENT_BACKUP_FILE}" "${GO_EXECUTABLE_DEST}")
            rollback_status=$?
        fi
        
        if [ ${rollback_status} -eq 0 ]; then
            log_message "Successfully rolled back to previous executable."
            
            # Try to restart the service with the old executable
            log_message "Attempting to restart service with previous executable..."
            rollback_restart_output=$(${SUDO_CMD} -n systemctl restart "${RC_SERVICE_NAME}" 2>&1)
            rollback_restart_status=$?
            
            if [ ${rollback_restart_status} -eq 0 ]; then
                log_message "Successfully restarted service with previous executable."
            else
                log_message "WARNING: Failed to restart service with previous executable. Output: ${rollback_restart_output}"
            fi
        else
            log_message "WARNING: Failed to roll back to previous executable. Output: ${rollback_output}"
        fi
    else
        log_message "WARNING: No backup file available for rollback."
    fi
    
    log_message "--- Script finished with errors ---"
    exit 1
else
    log_message "systemd service ${RC_SERVICE_NAME} restarted successfully with the new executable."
    # If restart was successful, clean up the backup made during this run
    if [ -n "${CURRENT_BACKUP_FILE}" ] && [ -f "${CURRENT_BACKUP_FILE}" ]; then
        log_message "Deleting backup file from this run: ${CURRENT_BACKUP_FILE}"
        delete_backup_output=$(${SUDO_CMD} -n rm -f "${CURRENT_BACKUP_FILE}" 2>&1)
        delete_backup_status=$?
        
        # If sudo fails with authentication error, try direct rm
        if [ ${delete_backup_status} -ne 0 ] && [[ "${delete_backup_output}" == *"sudo: a password is required"* ]]; then
            log_message "sudo authentication required. Trying direct rm for backup file..."
            delete_backup_output=$(attempt_direct_file_op "rm" "${CURRENT_BACKUP_FILE}" "")
            delete_backup_status=$?
        fi
        
        if [ ${delete_backup_status} -eq 0 ]; then
            log_message "Successfully deleted backup file ${CURRENT_BACKUP_FILE}."
        else
            log_message "WARNING: Failed to delete backup file ${CURRENT_BACKUP_FILE}."
            log_message "Delete backup output: ${delete_backup_output}"
        fi
    fi
    
    log_message "--- Script finished successfully ---"
    exit 0
fi