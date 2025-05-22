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
        # Log each deleted file name
        echo "$deleted_logs_output" | while IFS= read -r line; do log_message "Deleted: $line"; done
    else
        log_message "No old log files (older than 90 days) found to delete."
    fi
else
    # find command itself failed
    log_message "ERROR during log cleanup. 'find' command failed with status ${find_exit_status}."
    if [ -n "$deleted_logs_output" ]; then # Log any output from find even on error
        log_message "Find command output/error: $deleted_logs_output"
    fi
fi
log_message "--- Log cleanup finished ---"
# --- End Log Cleanup ---

# Ensure current day's log file is writable (or can be created)
# log_message itself would have created LOG_DIR. Now ensure the file is touchable.
if ! touch "${LOG_FILE}" >/dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - CRITICAL: Current log file ${LOG_FILE} is not writable or cannot be created. Exiting." >&2
    exit 1
fi

log_message "--- Script started ---" # Main script operational log start

# Check if repository directory exists
if [ ! -d "${REPO_PATH}" ]; then
    log_message "ERROR: Repository directory ${REPO_PATH} not found. Exiting."
    exit 1
fi

# Check if project directory exists
if [ ! -d "${PROJECT_DIR}" ]; then
    log_message "ERROR: Project directory ${PROJECT_DIR} not found. Exiting."
    exit 1
fi

# --- Git Operations ---

# Change to the repository directory for Git operations
cd "${REPO_PATH}" || {
    log_message "ERROR: Could not navigate to repository directory ${REPO_PATH}. Exiting."
    exit 1
}

log_message "Successfully navigated to repository directory: ${REPO_PATH}"

# Function to handle Git dubious ownership errors
handle_git_dubious_ownership() {
    local git_output=$1
    local repo_path=""
    
    # Extract the repository path from the error message
    if [[ "${git_output}" == *"detected dubious ownership in repository at"* ]]; then
        # Extract the path between single quotes
        repo_path=$(echo "${git_output}" | grep -o "'[^']*'" | sed "s/'//g")
        
        if [ -n "${repo_path}" ]; then
            log_message "Detected Git dubious ownership error for repository: ${repo_path}"
            log_message "Automatically configuring Git to trust this directory"
            
            # Run the git config command to add the directory as safe
            safe_dir_output=$(${GIT_CMD} config --global --add safe.directory "${repo_path}" 2>&1)
            safe_dir_status=$?
            
            if [ ${safe_dir_status} -eq 0 ]; then
                log_message "Successfully added ${repo_path} to Git safe.directory"
                return 0
            else
                log_message "Failed to add ${repo_path} to Git safe.directory: ${safe_dir_output}"
                return 1
            fi
        fi
    fi
    
    # If we didn't find a dubious ownership error or couldn't extract the path
    return 1
}

# Store current commit hash to check for changes later
current_commit_before_pull=$(${GIT_CMD} rev-parse HEAD 2>&1)
rev_parse_status=$?
if [ ${rev_parse_status} -ne 0 ]; then
    # Check if this is a dubious ownership error
    if [[ "${current_commit_before_pull}" == *"detected dubious ownership"* ]]; then
        log_message "Git dubious ownership error detected during rev-parse"
        if handle_git_dubious_ownership "${current_commit_before_pull}"; then
            # Try again after fixing the ownership issue
            log_message "Retrying rev-parse after fixing ownership issue"
            current_commit_before_pull=$(${GIT_CMD} rev-parse HEAD 2>&1)
            rev_parse_status=$?
            
            if [ ${rev_parse_status} -ne 0 ]; then
                log_message "WARNING: Could not get current commit hash before pull even after fixing ownership. Assuming changes are needed."
                current_commit_before_pull="unknown_before_pull_error" # Set to a value that won't match after_pull
            fi
        else
            log_message "WARNING: Could not fix Git dubious ownership issue. Assuming changes are needed."
            current_commit_before_pull="unknown_before_pull_error" # Set to a value that won't match after_pull
        fi
    else
        log_message "WARNING: Could not get current commit hash before pull. Assuming changes are needed."
        current_commit_before_pull="unknown_before_pull_error" # Set to a value that won't match after_pull
    fi
fi

# Pull latest changes from the repository
log_message "Attempting to pull latest changes from Git repository..."
git_pull_output=""

# Function to attempt git pull without doas
attempt_direct_pull() {
    log_message "Attempting direct git pull without doas..."
    git_pull_output=$(${GIT_CMD} pull 2>&1)
    pull_status=$?
    
    # Check for dubious ownership error
    if [ ${pull_status} -ne 0 ] && [[ "${git_pull_output}" == *"detected dubious ownership"* ]]; then
        log_message "Git dubious ownership error detected during pull"
        if handle_git_dubious_ownership "${git_pull_output}"; then
            # Try again after fixing the ownership issue
            log_message "Retrying pull after fixing ownership issue"
            git_pull_output=$(${GIT_CMD} pull 2>&1)
            pull_status=$?
        fi
    fi
    
    return ${pull_status}
}

if [ -n "${BUILD_USER}" ]; then
    # Try with doas first
    git_pull_output=$(${DOAS_CMD} -n -u ${BUILD_USER} ${GIT_CMD} pull 2>&1)
    git_pull_status=$?
    
    # If doas fails with authentication error and this is likely a public repo, try direct pull
    if [ ${git_pull_status} -ne 0 ] && [[ "${git_pull_output}" == *"doas: Authentication required"* ]]; then
        log_message "doas authentication required. Trying direct git pull as this might be a public repository..."
        attempt_direct_pull
        git_pull_status=$?
    fi
else
    # No BUILD_USER, use direct git pull
    attempt_direct_pull
    git_pull_status=$?
fi

if [ ${git_pull_status} -ne 0 ]; then
    log_message "ERROR: Git pull failed with status ${git_pull_status}."
    log_message "Git output: ${git_pull_output}"
    log_message "--- Script finished with errors ---"
    exit 1
fi
log_message "Git pull successful."
log_message "Git output: ${git_pull_output}"

# Check if there were any actual changes
current_commit_after_pull=$(${GIT_CMD} rev-parse HEAD 2>&1)
rev_parse_after_status=$?
if [ ${rev_parse_after_status} -ne 0 ]; then
    # Check if this is a dubious ownership error
    if [[ "${current_commit_after_pull}" == *"detected dubious ownership"* ]]; then
        log_message "Git dubious ownership error detected during after-pull rev-parse"
        if handle_git_dubious_ownership "${current_commit_after_pull}"; then
            # Try again after fixing the ownership issue
            log_message "Retrying after-pull rev-parse after fixing ownership issue"
            current_commit_after_pull=$(${GIT_CMD} rev-parse HEAD 2>&1)
            rev_parse_after_status=$?
            
            if [ ${rev_parse_after_status} -ne 0 ]; then
                log_message "WARNING: Could not get current commit hash after pull even after fixing ownership. Assuming changes were made."
                # To force a rebuild in case of error, ensure it doesn't match 'before_pull' if 'before_pull' was also an error
                if [ "${current_commit_before_pull}" == "unknown_before_pull_error" ]; then
                  current_commit_after_pull="unknown_after_pull_error_forcing_rebuild"
                else
                  current_commit_after_pull="unknown_after_pull_error" # Will likely not match 'before_pull'
                fi
            fi
        else
            log_message "WARNING: Could not fix Git dubious ownership issue after pull. Assuming changes were made."
            if [ "${current_commit_before_pull}" == "unknown_before_pull_error" ]; then
              current_commit_after_pull="unknown_after_pull_error_forcing_rebuild"
            else
              current_commit_after_pull="unknown_after_pull_error" # Will likely not match 'before_pull'
            fi
        fi
    else
        log_message "WARNING: Could not get current commit hash after pull. Assuming changes were made and proceeding with rebuild."
        # To force a rebuild in case of error, ensure it doesn't match 'before_pull' if 'before_pull' was also an error
        if [ "${current_commit_before_pull}" == "unknown_before_pull_error" ]; then
          current_commit_after_pull="unknown_after_pull_error_forcing_rebuild"
        else
          current_commit_after_pull="unknown_after_pull_error" # Will likely not match 'before_pull'
        fi
    fi
fi

rebuild_needed=true # Default to rebuild needed
if [ "${current_commit_before_pull}" == "${current_commit_after_pull}" ]; then
    # Hashes are the same. Check git output for more clues.
    if [[ "${git_pull_output}" == *"Already up to date."* || "${git_pull_output}" == *"Already up-to-date."* ]]; then
        log_message "No new code changes pulled (Git: Already up to date). Commit hash unchanged. Nothing to rebuild."
        rebuild_needed=false
    elif [[ ! "${git_pull_output}" == *"Updating"* ]]; then
        # Hashes same, and no "Updating" message.
        log_message "No new code changes pulled (commit hash unchanged and no 'Updating' in output). Nothing to rebuild."
        rebuild_needed=false
    else
        # Hashes same, but "Updating" was in the output (e.g., for tags, submodules without commit change).
        log_message "Commit hash unchanged, but 'Updating' keyword found in pull output. Proceeding with rebuild."
    fi
fi

if [ "${rebuild_needed}" = false ] && [ "${FORCE_REBUILD}" = false ]; then
    log_message "--- Script finished successfully (no changes and --force not specified) ---"
    exit 0
elif [ "${rebuild_needed}" = false ] && [ "${FORCE_REBUILD}" = true ]; then
    log_message "No changes detected but --force specified. Proceeding with rebuild anyway."
    rebuild_needed=true
fi

log_message "Changes detected or rebuild forced. Proceeding with rebuild."

# --- Change to the project directory for building ---
if [ "${REPO_PATH}" != "${PROJECT_DIR}" ]; then
    cd "${PROJECT_DIR}" || {
        log_message "ERROR: Failed to change to project directory ${PROJECT_DIR}."
        exit 1
    }
    log_message "Changed to project directory: ${PROJECT_DIR}"
fi

# Rebuild the Go application
log_message "Rebuilding Go application (${GO_EXECUTABLE_NAME})..."
# Define a temporary build path. Using mktemp for a unique temporary file name.
# The temporary file will be in the same directory as the final executable for easier 'mv'.
EXECUTABLE_DIR=$(dirname "${GO_EXECUTABLE_DEST}")
TMP_BUILD_FILE=$(mktemp "${EXECUTABLE_DIR}/${GO_EXECUTABLE_NAME}.tmp.XXXXXX")
if [ $? -ne 0 ]; then
    log_message "ERROR: Could not create temporary file for build. Exiting."
    log_message "--- Script finished with errors ---"
    exit 1
fi
log_message "Building to temporary file: ${TMP_BUILD_FILE}"

build_output=""
if [ -n "${BUILD_USER}" ]; then
    # Define and ensure Go cache directories exist and are writable by BUILD_USER
    # These will be created within the project directory.
    GOCACHE_DIR="${PROJECT_DIR}/.gocache"
    GOMODCACHE_DIR="${PROJECT_DIR}/.gomodcache" # For Go modules
    
    log_message "Ensuring Go cache directories exist for ${BUILD_USER} at ${GOCACHE_DIR} and ${GOMODCACHE_DIR}"
    
    # Function to attempt direct mkdir without doas
    attempt_direct_mkdir() {
        local dir=$1
        log_message "Attempting direct mkdir for ${dir} without doas..."
        mkdir -p "${dir}" 2>&1
        return $?
    }
    
    # Try to create cache dirs as BUILD_USER
    mkdir_gocache_output=$(${DOAS_CMD} -n -u ${BUILD_USER} mkdir -p "${GOCACHE_DIR}" 2>&1)
    mkdir_gocache_status=$?
    if [ ${mkdir_gocache_status} -ne 0 ]; then
        if [[ "${mkdir_gocache_output}" == *"doas: Authentication required"* ]]; then
            log_message "doas authentication required. Trying direct mkdir for GOCACHE_DIR..."
            attempt_direct_mkdir "${GOCACHE_DIR}"
        else
            log_message "WARNING: Could not create GOCACHE_DIR (${GOCACHE_DIR}) as ${BUILD_USER}. Output: ${mkdir_gocache_output}"
            # Depending on Go version, build might still proceed if cache is not critical or uses another fallback.
        fi
    fi
    
    mkdir_gomodcache_output=$(${DOAS_CMD} -n -u ${BUILD_USER} mkdir -p "${GOMODCACHE_DIR}" 2>&1)
    mkdir_gomodcache_status=$?
    if [ ${mkdir_gomodcache_status} -ne 0 ]; then
        if [[ "${mkdir_gomodcache_output}" == *"doas: Authentication required"* ]]; then
            log_message "doas authentication required. Trying direct mkdir for GOMODCACHE_DIR..."
            attempt_direct_mkdir "${GOMODCACHE_DIR}"
        else
            log_message "WARNING: Could not create GOMODCACHE_DIR (${GOMODCACHE_DIR}) as ${BUILD_USER}. Output: ${mkdir_gomodcache_output}"
        fi
    fi

    log_message "Executing go build with GOCACHE=${GOCACHE_DIR} GOMODCACHE=${GOMODCACHE_DIR}"
    
    # Ensure the build output directory exists and has proper permissions
    BUILD_OUTPUT_DIR="$(dirname "${TMP_BUILD_FILE}")"
    log_message "Ensuring build output directory exists and has proper permissions: ${BUILD_OUTPUT_DIR}"
    
    # Create tmp directory if it doesn't exist
    if [ ! -d "${BUILD_OUTPUT_DIR}" ]; then
        log_message "Build output directory does not exist, creating it..."
        
        # First try with doas
        mkdir_output=$(${DOAS_CMD} -n mkdir -p "${BUILD_OUTPUT_DIR}" 2>&1)
        mkdir_status=$?
        
        # If doas fails, try direct mkdir
        if [ ${mkdir_status} -ne 0 ] && [[ "${mkdir_output}" == *"doas: Authentication required"* ]]; then
            log_message "doas authentication required. Trying direct mkdir..."
            mkdir_output=$(mkdir -p "${BUILD_OUTPUT_DIR}" 2>&1)
            mkdir_status=$?
        fi
        
        if [ ${mkdir_status} -ne 0 ]; then
            log_message "WARNING: Failed to create build output directory. Build will fail. Output: ${mkdir_output}"
        else
            log_message "Successfully created build output directory"
        fi
    fi
    
    # First try with doas
    chmod_output=$(${DOAS_CMD} -n chmod 775 "${BUILD_OUTPUT_DIR}" 2>&1)
    chmod_status=$?
    
    # If doas fails, try direct chmod
    if [ ${chmod_status} -ne 0 ] && [[ "${chmod_output}" == *"doas: Authentication required"* ]]; then
        log_message "doas authentication required. Trying direct chmod..."
        chmod_output=$(chmod 775 "${BUILD_OUTPUT_DIR}" 2>&1)
        chmod_status=$?
    fi
    
    if [ ${chmod_status} -ne 0 ]; then
        log_message "WARNING: Failed to set permissions on build output directory. Build may fail. Output: ${chmod_output}"
    else
        log_message "Successfully set permissions on build output directory"
    fi
    
    # Set ownership of the build output directory to BUILD_USER if specified
    if [ -n "${BUILD_USER}" ]; then
        log_message "Setting ownership of build output directory to ${BUILD_USER}"
        
        # First try with doas
        chown_output=$(${DOAS_CMD} -n chown ${BUILD_USER}:${BUILD_USER} "${BUILD_OUTPUT_DIR}" 2>&1)
        chown_status=$?
        
        # If doas fails, try direct chown (though this will likely fail without root)
        if [ ${chown_status} -ne 0 ] && [[ "${chown_output}" == *"doas: Authentication required"* ]]; then
            log_message "doas authentication required for chown. This will likely fail without root privileges."
            log_message "Continuing anyway, but build may fail due to permission issues."
        elif [ ${chown_status} -ne 0 ]; then
            log_message "WARNING: Failed to set ownership of build output directory. Build may fail. Output: ${chown_output}"
        else
            log_message "Successfully set ownership of build output directory to ${BUILD_USER}"
        fi
    fi
    # Try with doas first
    build_output=$(${DOAS_CMD} -n -u ${BUILD_USER} env GOCACHE="${GOCACHE_DIR}" GOMODCACHE="${GOMODCACHE_DIR}" ${GO_CMD} build -buildvcs=false -o "${TMP_BUILD_FILE}" . 2>&1)
    build_status=$?
    
    # If doas fails with authentication error, try direct build
    if [ ${build_status} -ne 0 ] && [[ "${build_output}" == *"doas: Authentication required"* ]]; then
        log_message "doas authentication required. Trying direct go build..."
        build_output=$(env GOCACHE="${GOCACHE_DIR}" GOMODCACHE="${GOMODCACHE_DIR}" ${GO_CMD} build -buildvcs=false -o "${TMP_BUILD_FILE}" . 2>&1)
        build_status=$?
    fi
else
    # For root or cron user without specific BUILD_USER, Go will use their default cache locations
    # or system-wide caches if configured.
    build_output=$(${GO_CMD} build -buildvcs=false -o "${TMP_BUILD_FILE}" . 2>&1)
    build_status=$?
fi

if [ ${build_status} -ne 0 ]; then
    log_message "ERROR: Go build failed with status ${build_status}."
    log_message "Build output: ${build_output}"
    rm -f "${TMP_BUILD_FILE}" # Clean up temporary file on build failure
    log_message "Cleaned up temporary build file: ${TMP_BUILD_FILE}"
    log_message "--- Script finished with errors ---"
    exit 1
fi
log_message "Go application built successfully to temporary file: ${TMP_BUILD_FILE}"

# Function to attempt direct file operations without doas
attempt_direct_file_op() {
    local op=$1
    local src=$2
    local dest=$3
    log_message "Attempting direct ${op} without doas: ${src} to ${dest}..."
    
    if [ "${op}" = "mv" ]; then
        mv "${src}" "${dest}" 2>&1
        return $?
    elif [ "${op}" = "rm" ]; then
        rm -f "${src}" 2>&1
        return $?
    fi
    return 1
}

# Backup old executable and move new one into place
if [ -f "${GO_EXECUTABLE_DEST}" ]; then
    CURRENT_BACKUP_FILE="${GO_EXECUTABLE_DEST}.bak_$(date '+%Y%m%d%H%M%S')"
    log_message "Backing up current executable ${GO_EXECUTABLE_DEST} to ${CURRENT_BACKUP_FILE}..."
    mv_backup_output=""
    # Moving files in system directories typically requires elevated privileges
    mv_backup_output=$(${DOAS_CMD} -n mv "${GO_EXECUTABLE_DEST}" "${CURRENT_BACKUP_FILE}" 2>&1)
    mv_backup_status=$?
    
    # If doas fails with authentication error, try direct mv
    if [ ${mv_backup_status} -ne 0 ] && [[ "${mv_backup_output}" == *"doas: Authentication required"* ]]; then
        log_message "doas authentication required. Trying direct mv for backup..."
        mv_backup_output=$(attempt_direct_file_op "mv" "${GO_EXECUTABLE_DEST}" "${CURRENT_BACKUP_FILE}")
        mv_backup_status=$?
    fi

    if [ ${mv_backup_status} -ne 0 ]; then
        log_message "ERROR: Failed to back up current executable ${GO_EXECUTABLE_DEST}."
        log_message "MV Backup output: ${mv_backup_output}"
        rm -f "${TMP_BUILD_FILE}" # Clean up new build as we couldn't backup
        log_message "Cleaned up temporary build file: ${TMP_BUILD_FILE}"
        log_message "--- Script finished with errors ---"
        exit 1
    fi
    log_message "Successfully backed up ${GO_EXECUTABLE_DEST} to ${CURRENT_BACKUP_FILE}"
else
    log_message "No existing executable at ${GO_EXECUTABLE_DEST} to back up."
fi

log_message "Moving new executable ${TMP_BUILD_FILE} to ${GO_EXECUTABLE_DEST}..."
mv_new_output=""
# Moving new executable also typically requires elevated privileges
mv_new_output=$(${DOAS_CMD} -n mv "${TMP_BUILD_FILE}" "${GO_EXECUTABLE_DEST}" 2>&1)
mv_new_status=$?

# If doas fails with authentication error, try direct mv
if [ ${mv_new_status} -ne 0 ] && [[ "${mv_new_output}" == *"doas: Authentication required"* ]]; then
    log_message "doas authentication required. Trying direct mv for new executable..."
    mv_new_output=$(attempt_direct_file_op "mv" "${TMP_BUILD_FILE}" "${GO_EXECUTABLE_DEST}")
    mv_new_status=$?
}

if [ ${mv_new_status} -ne 0 ]; then
    log_message "ERROR: Failed to move new executable from ${TMP_BUILD_FILE} to ${GO_EXECUTABLE_DEST}."
    log_message "MV New output: ${mv_new_output}"
    log_message "WARNING: New build is at ${TMP_BUILD_FILE}."
    if [ -n "${CURRENT_BACKUP_FILE}" ] && [ -f "${CURRENT_BACKUP_FILE}" ]; then
        log_message "Attempting to restore backup ${CURRENT_BACKUP_FILE} to ${GO_EXECUTABLE_DEST} due to move failure..."
        restore_output=$(${DOAS_CMD} -n mv "${CURRENT_BACKUP_FILE}" "${GO_EXECUTABLE_DEST}" 2>&1)
        restore_status=$?
        
        # If doas fails with authentication error, try direct mv
        if [ ${restore_status} -ne 0 ] && [[ "${restore_output}" == *"doas: Authentication required"* ]]; then
            log_message "doas authentication required. Trying direct mv for restore..."
            restore_output=$(attempt_direct_file_op "mv" "${CURRENT_BACKUP_FILE}" "${GO_EXECUTABLE_DEST}")
            restore_status=$?
        fi
        
        if [ ${restore_status} -eq 0 ]; then
            log_message "Successfully restored backup to ${GO_EXECUTABLE_DEST}."
        else
            log_message "ERROR: Failed to restore backup. System may be in an inconsistent state."
            log_message "Restore output: ${restore_output}"
        fi
    fi
    log_message "--- Script finished with errors ---"
    exit 1
fi
log_message "Successfully moved new executable to ${GO_EXECUTABLE_DEST}"


# Function to attempt direct service restart without doas
attempt_direct_service_restart() {
    log_message "Attempting direct service restart without doas..."
    ${RC_SERVICE_CMD} "${RC_SERVICE_NAME}" restart 2>&1
    return $?
}

# Restart the rc-service
log_message "Attempting to restart rc-service ${RC_SERVICE_NAME}..."
restart_output=$(${DOAS_CMD} -n ${RC_SERVICE_CMD} "${RC_SERVICE_NAME}" restart 2>&1)
restart_status=$?

# If doas fails with authentication error, try direct restart
if [ ${restart_status} -ne 0 ] && [[ "${restart_output}" == *"doas: Authentication required"* ]]; then
    log_message "doas authentication required. Trying direct service restart..."
    restart_output=$(attempt_direct_service_restart)
    restart_status=$?
}

if [ ${restart_status} -ne 0 ]; then
    log_message "ERROR: Failed to restart rc-service ${RC_SERVICE_NAME} with status ${restart_status}."
    log_message "Restart output: ${restart_output}"
    log_message "Attempting to roll back to previous executable..."
    if [ -n "${CURRENT_BACKUP_FILE}" ] && [ -f "${CURRENT_BACKUP_FILE}" ]; then
        log_message "Moving backup ${CURRENT_BACKUP_FILE} back to ${GO_EXECUTABLE_DEST}."
        rollback_output=$(${DOAS_CMD} -n mv "${CURRENT_BACKUP_FILE}" "${GO_EXECUTABLE_DEST}" 2>&1)
        rollback_status=$?
        
        # If doas fails with authentication error, try direct mv
        if [ ${rollback_status} -ne 0 ] && [[ "${rollback_output}" == *"doas: Authentication required"* ]]; then
            log_message "doas authentication required. Trying direct mv for rollback..."
            rollback_output=$(attempt_direct_file_op "mv" "${CURRENT_BACKUP_FILE}" "${GO_EXECUTABLE_DEST}")
            rollback_status=$?
        fi
        
        if [ ${rollback_status} -eq 0 ]; then
            log_message "Rollback successful. Service ${RC_SERVICE_NAME} may need to be started manually or with another restart attempt."
            # Optionally, try to restart the service again with the old executable
            log_message "Attempting to restart service with rolled-back executable..."
            ${DOAS_CMD} -n ${RC_SERVICE_CMD} "${RC_SERVICE_NAME}" restart 2>> "${LOG_FILE}"
            log_message "Rollback restart attempt completed."
        else
            log_message "ERROR: Rollback failed. Could not move ${CURRENT_BACKUP_FILE} to ${GO_EXECUTABLE_DEST}."
            log_message "Rollback MV output: ${rollback_output}"
            log_message "System may be in an inconsistent state. The new (failed) executable might still be at ${GO_EXECUTABLE_DEST} if this was the first version."
        fi
    else
        log_message "No backup file from this run available to roll back to."
    fi
    log_message "--- Script finished with errors (restart failed) ---"
    exit 1
else
    log_message "rc-service ${RC_SERVICE_NAME} restarted successfully with the new executable."
    # If restart was successful, clean up the backup made during this run
    if [ -n "${CURRENT_BACKUP_FILE}" ] && [ -f "${CURRENT_BACKUP_FILE}" ]; then
        log_message "Deleting backup file from this run: ${CURRENT_BACKUP_FILE}"
        delete_backup_output=$(${DOAS_CMD} -n rm -f "${CURRENT_BACKUP_FILE}" 2>&1)
        delete_backup_status=$?

        # If doas fails with authentication error, try direct rm
        if [ ${delete_backup_status} -ne 0 ] && [[ "${delete_backup_output}" == *"doas: Authentication required"* ]]; then
            log_message "doas authentication required. Trying direct rm for backup file..."
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
