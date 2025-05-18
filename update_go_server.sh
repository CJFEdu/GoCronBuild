#!/bin/bash

# --- Configuration ---
# !!! IMPORTANT: Set these variables to match your environment !!!

# Full path to your Go project's Git repository
PROJECT_DIR="/path/to/your/go/project"

# The name of your Go application's main executable after building
# (e.g., if your main.go produces 'mygoserver', set this to 'mygoserver')
GO_EXECUTABLE_NAME="yourgoserver"

# The full path where the compiled Go executable should be placed
# This is the path that your rc-service init script's 'command' variable points to.
# Example: GO_EXECUTABLE_DEST="/usr/local/bin/${GO_EXECUTABLE_NAME}"
GO_EXECUTABLE_DEST="/usr/local/bin/${GO_EXECUTABLE_NAME}"

# The name of your rc-service
RC_SERVICE_NAME="mygoserver"

# Directory for all log files of this script
LOG_DIR="/var/log/go_project_updater"
LOG_BASE_NAME="go_project_updater" # Base name for log files

# User to run git and go build commands as (if different from cron user)
# Leave empty if the cron user has direct permissions.
# If set, script will attempt to use 'doas -u ${BUILD_USER}' for git and go commands.
# This user needs write access to PROJECT_DIR and GOCACHE, GOPATH if applicable.
BUILD_USER="" # e.g., "yourgouser"

# Git command (use absolute path if not in cron's default PATH)
GIT_CMD="/usr/bin/git" # Adjust if your git path is different

# Go command (use absolute path if not in cron's default PATH)
GO_CMD="/usr/local/go/bin/go" # Adjust if your go path is different (e.g., /usr/bin/go if installed via apk)

# rc-service command (use absolute path)
RC_SERVICE_CMD="/sbin/rc-service"

# doas command (use absolute path)
DOAS_CMD="/usr/bin/doas" # Adjust if your doas path is different

# --- Script Logic ---

CURRENT_DATE=$(date '+%Y-%m-%d')
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

# Check if project directory exists
if [ ! -d "${PROJECT_DIR}" ]; then
    log_message "ERROR: Project directory ${PROJECT_DIR} not found. Exiting."
    log_message "--- Script finished with errors ---"
    exit 1
fi

# Navigate to the project directory
cd "${PROJECT_DIR}" || {
    log_message "ERROR: Could not navigate to project directory ${PROJECT_DIR}. Exiting."
    log_message "--- Script finished with errors ---"
    exit 1
}
log_message "Successfully navigated to ${PROJECT_DIR}"

# Store current commit hash to check for changes later
current_commit_before_pull=$(${GIT_CMD} rev-parse HEAD 2>> "${LOG_FILE}")
if [ $? -ne 0 ]; then
    log_message "WARNING: Could not get current commit hash before pull. Assuming changes are needed."
    current_commit_before_pull="unknown_before_pull_error" # Set to a value that won't match after_pull
fi

# Pull latest changes from the repository
log_message "Attempting to pull latest changes from Git repository..."
git_pull_output=""
if [ -n "${BUILD_USER}" ]; then
    git_pull_output=$(${DOAS_CMD} -u "${BUILD_USER}" ${GIT_CMD} pull 2>&1)
else
    git_pull_output=$(${GIT_CMD} pull 2>&1)
fi
git_pull_status=$?

if [ ${git_pull_status} -ne 0 ]; then
    log_message "ERROR: Git pull failed with status ${git_pull_status}."
    log_message "Git output: ${git_pull_output}"
    log_message "--- Script finished with errors ---"
    exit 1
fi
log_message "Git pull successful."
log_message "Git output: ${git_pull_output}"

# Check if there were any actual changes
current_commit_after_pull=$(${GIT_CMD} rev-parse HEAD 2>> "${LOG_FILE}")
if [ $? -ne 0 ]; then
    log_message "WARNING: Could not get current commit hash after pull. Assuming changes were made and proceeding with rebuild."
    # To force a rebuild in case of error, ensure it doesn't match 'before_pull' if 'before_pull' was also an error
    if [ "${current_commit_before_pull}" == "unknown_before_pull_error" ]; then
      current_commit_after_pull="unknown_after_pull_error_forcing_rebuild"
    else
      current_commit_after_pull="unknown_after_pull_error" # Will likely not match 'before_pull'
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

if [ "${rebuild_needed}" = false ]; then
    log_message "--- Script finished successfully (no changes) ---"
    exit 0
fi

log_message "Changes detected or rebuild forced. Proceeding with rebuild."

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
    # Create cache dirs as BUILD_USER. Output/errors from mkdir will go to the main log.
    mkdir_gocache_output=$(${DOAS_CMD} -u "${BUILD_USER}" mkdir -p "${GOCACHE_DIR}" 2>&1)
    if [ $? -ne 0 ]; then
        log_message "WARNING: Could not create GOCACHE_DIR (${GOCACHE_DIR}) as ${BUILD_USER}. Output: ${mkdir_gocache_output}"
        # Depending on Go version, build might still proceed if cache is not critical or uses another fallback.
    fi
    mkdir_gomodcache_output=$(${DOAS_CMD} -u "${BUILD_USER}" mkdir -p "${GOMODCACHE_DIR}" 2>&1)
    if [ $? -ne 0 ]; then
        log_message "WARNING: Could not create GOMODCACHE_DIR (${GOMODCACHE_DIR}) as ${BUILD_USER}. Output: ${mkdir_gomodcache_output}"
    fi

    log_message "Executing go build as ${BUILD_USER} with GOCACHE=${GOCACHE_DIR} GOMODCACHE=${GOMODCACHE_DIR}"
    build_output=$(${DOAS_CMD} -u "${BUILD_USER}" env GOCACHE="${GOCACHE_DIR}" GOMODCACHE="${GOMODCACHE_DIR}" ${GO_CMD} build -o "${TMP_BUILD_FILE}" . 2>&1)
else
    # For root or cron user without specific BUILD_USER, Go will use their default cache locations
    # or system-wide caches if configured.
    build_output=$(${GO_CMD} build -o "${TMP_BUILD_FILE}" . 2>&1)
fi
build_status=$?

if [ ${build_status} -ne 0 ]; then
    log_message "ERROR: Go build failed with status ${build_status}."
    log_message "Build output: ${build_output}"
    rm -f "${TMP_BUILD_FILE}" # Clean up temporary file on build failure
    log_message "Cleaned up temporary build file: ${TMP_BUILD_FILE}"
    log_message "--- Script finished with errors ---"
    exit 1
fi
log_message "Go application built successfully to temporary file: ${TMP_BUILD_FILE}"

# Backup old executable and move new one into place
if [ -f "${GO_EXECUTABLE_DEST}" ]; then
    CURRENT_BACKUP_FILE="${GO_EXECUTABLE_DEST}.bak_$(date '+%Y%m%d%H%M%S')"
    log_message "Backing up current executable ${GO_EXECUTABLE_DEST} to ${CURRENT_BACKUP_FILE}..."
    mv_backup_output=""
    # Moving files in system directories typically requires elevated privileges
    mv_backup_output=$(${DOAS_CMD} mv "${GO_EXECUTABLE_DEST}" "${CURRENT_BACKUP_FILE}" 2>&1)
    mv_backup_status=$?

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
mv_new_output=$(${DOAS_CMD} mv "${TMP_BUILD_FILE}" "${GO_EXECUTABLE_DEST}" 2>&1)
mv_new_status=$?

if [ ${mv_new_status} -ne 0 ]; then
    log_message "ERROR: Failed to move new executable from ${TMP_BUILD_FILE} to ${GO_EXECUTABLE_DEST}."
    log_message "MV New output: ${mv_new_output}"
    log_message "WARNING: New build is at ${TMP_BUILD_FILE}."
    if [ -n "${CURRENT_BACKUP_FILE}" ] && [ -f "${CURRENT_BACKUP_FILE}" ]; then
        log_message "Attempting to restore backup ${CURRENT_BACKUP_FILE} to ${GO_EXECUTABLE_DEST} due to move failure..."
        restore_output=$(${DOAS_CMD} mv "${CURRENT_BACKUP_FILE}" "${GO_EXECUTABLE_DEST}" 2>&1)
        if [ $? -eq 0 ]; then
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


# Restart the rc-service
log_message "Attempting to restart rc-service ${RC_SERVICE_NAME}..."
restart_output=$(${DOAS_CMD} ${RC_SERVICE_CMD} "${RC_SERVICE_NAME}" restart 2>&1)
restart_status=$?

if [ ${restart_status} -ne 0 ]; then
    log_message "ERROR: Failed to restart rc-service ${RC_SERVICE_NAME} with status ${restart_status}."
    log_message "Restart output: ${restart_output}"
    log_message "Attempting to roll back to previous executable..."
    if [ -n "${CURRENT_BACKUP_FILE}" ] && [ -f "${CURRENT_BACKUP_FILE}" ]; then
        log_message "Moving backup ${CURRENT_BACKUP_FILE} back to ${GO_EXECUTABLE_DEST}."
        rollback_output=$(${DOAS_CMD} mv "${CURRENT_BACKUP_FILE}" "${GO_EXECUTABLE_DEST}" 2>&1)
        if [ $? -eq 0 ]; then
            log_message "Rollback successful. Service ${RC_SERVICE_NAME} may need to be started manually or with another restart attempt."
            # Optionally, try to restart the service again with the old executable
            log_message "Attempting to restart service with rolled-back executable..."
            ${DOAS_CMD} ${RC_SERVICE_CMD} "${RC_SERVICE_NAME}" restart 2>> "${LOG_FILE}"
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
        delete_backup_output=$(${DOAS_CMD} rm -f "${CURRENT_BACKUP_FILE}" 2>&1)
        if [ $? -eq 0 ]; then
            log_message "Successfully deleted backup file ${CURRENT_BACKUP_FILE}."
        else
            log_message "WARNING: Failed to delete backup file ${CURRENT_BACKUP_FILE}."
            log_message "Delete backup output: ${delete_backup_output}"
        fi
    fi
    log_message "--- Script finished successfully ---"
    exit 0
fi
