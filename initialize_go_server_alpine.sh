#!/bin/bash

# --- Initialize Go Server Script ---
# This script automates the process of setting up a Go application on Alpine Linux:
# 1. Clones the Git repository
# 2. Builds the Go application
# 3. Creates an OpenRC service
# 4. Starts the service
# 5. Enables the service to start on boot

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

# --- Logging Setup ---
CURRENT_DATE=$(date '+%Y-%m-%d')
LOG_FILE="${LOG_DIR}/${LOG_BASE_NAME}_init_${CURRENT_DATE}.log"

# Function to log messages with a timestamp
log_message() {
    # Ensure log directory exists before trying to write the first message.
    if ! mkdir -p "${LOG_DIR}" >/dev/null 2>&1; then
        # If log directory creation fails, echo to stderr as we can't use LOG_FILE
        echo "$(date '+%Y-%m-%d %H:%M:%S') - CRITICAL: Log directory ${LOG_DIR} could not be created. Logging to this file will fail. Exiting." >&2
        exit 1; # Exit if we can't even create the log directory
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOG_FILE}"
}

# --- Validation ---
# Check required variables
log_message "Starting initialization process..."
log_message "Validating configuration..."

MISSING_VARS=0
check_var() {
    local var_name=$1
    local var_value=$2
    if [ -z "$var_value" ]; then
        log_message "ERROR: Required variable $var_name is not set in config.sh"
        MISSING_VARS=$((MISSING_VARS+1))
    fi
}

check_var "PROJECT_DIR" "${PROJECT_DIR}"
check_var "GO_EXECUTABLE_NAME" "${GO_EXECUTABLE_NAME}"
check_var "GO_EXECUTABLE_DEST" "${GO_EXECUTABLE_DEST}"
check_var "RC_SERVICE_NAME" "${RC_SERVICE_NAME}"
check_var "GIT_REPO_URL" "${GIT_REPO_URL}"
check_var "GIT_BRANCH" "${GIT_BRANCH}"
check_var "GIT_CMD" "${GIT_CMD}"
check_var "GO_CMD" "${GO_CMD}"
check_var "RC_SERVICE_CMD" "${RC_SERVICE_CMD}"
check_var "DOAS_CMD" "${DOAS_CMD}"
check_var "REPO_PATH" "${REPO_PATH}"

if [ ${MISSING_VARS} -gt 0 ]; then
    log_message "ERROR: ${MISSING_VARS} required variable(s) missing. Please update your config.sh"
    exit 1
fi

log_message "Configuration validated successfully."

# --- Step 1: Clone the repository ---
log_message "Step 1: Cloning repository..."

# Check if repository directory already exists
if [ -d "${REPO_PATH}" ]; then
    log_message "Repository directory already exists: ${REPO_PATH}"
    read -p "Do you want to remove it and start fresh? (y/n): " -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "${REPO_PATH}" || {
            log_message "ERROR: Failed to change to repository directory ${REPO_PATH}."
            exit 1
        }
        
        # Check if it's a git repository
        if [ -d ".git" ]; then
            # Get the remote URL to confirm it's the right repository
            REMOTE_URL=$(${GIT_CMD} config --get remote.origin.url 2>/dev/null)
            if [ -n "${REMOTE_URL}" ]; then
                log_message "Current repository URL: ${REMOTE_URL}"
                if [ "${REMOTE_URL}" != "${GIT_REPO_URL}" ]; then
                    log_message "WARNING: Current repository URL does not match the configured URL."
                    read -p "Continue anyway? (y/n): " -r
                    echo
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        log_message "Aborting initialization."
                        exit 1
                    fi
                fi
            fi
        else
            log_message "ERROR: Directory exists but is not a Git repository: ${REPO_PATH}"
            read -p "Remove it and clone fresh? (y/n): " -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_message "Aborting initialization."
                exit 1
            fi
        fi
        
        log_message "Removing existing directory..."
        cd .. || {
            log_message "ERROR: Failed to change to parent directory."
            exit 1
        }
        rm -rf "${REPO_PATH}"
        log_message "Directory removed."
    fi
fi

# Create parent directory if needed
PARENT_DIR=$(dirname "${REPO_PATH}")
if [ ! -d "${PARENT_DIR}" ]; then
    log_message "Creating parent directory: ${PARENT_DIR}"
    mkdir -p "${PARENT_DIR}" || {
        log_message "ERROR: Failed to create parent directory."
        exit 1
    }
fi

# Ensure PROJECT_DIR parent directories exist
PROJECT_PARENT_DIR=$(dirname "${PROJECT_DIR}")
if [ ! -d "${PROJECT_PARENT_DIR}" ] && [ "${PROJECT_PARENT_DIR}" != "${REPO_PATH}" ]; then
    log_message "Creating project parent directory: ${PROJECT_PARENT_DIR}"
    mkdir -p "${PROJECT_PARENT_DIR}" || {
        log_message "ERROR: Failed to create project parent directory. Exiting."
        exit 1
    }
fi

# Use BUILD_USER if specified
if [ -n "${BUILD_USER}" ]; then
    log_message "Cloning as user: ${BUILD_USER}"
    # Ensure the parent directory has proper permissions for BUILD_USER
    if [ -d "${PARENT_DIR}" ]; then
        log_message "Setting permissions on parent directory for ${BUILD_USER}..."
        ${DOAS_CMD} chown "${BUILD_USER}" "${PARENT_DIR}"
    fi
    
    git_clone_output=$(${DOAS_CMD} -u "${BUILD_USER}" ${GIT_CMD} clone -b "${GIT_BRANCH}" "${GIT_REPO_URL}" "${REPO_PATH}" 2>&1)
else
    git_clone_output=$(${GIT_CMD} clone -b "${GIT_BRANCH}" "${GIT_REPO_URL}" "${REPO_PATH}" 2>&1)
fi
git_clone_status=$?

if [ ${git_clone_status} -ne 0 ]; then
    log_message "ERROR: Failed to clone repository. Output: ${git_clone_output}"
    exit 1
fi

log_message "Repository cloned successfully to ${REPO_PATH}."

# --- Step 2: Build the Go application ---
log_message "Step 2: Building Go application..."

# Change to the project directory
cd "${PROJECT_DIR}" || {
    log_message "ERROR: Failed to change to project directory ${PROJECT_DIR}."
    exit 1
}
log_message "Changed to project directory: ${PROJECT_DIR}"

# Create a temporary build directory within the project directory
TMP_BUILD_DIR="${PROJECT_DIR}/tmp"
log_message "Creating temporary build directory: ${TMP_BUILD_DIR}"
mkdir -p "${TMP_BUILD_DIR}" || {
    log_message "ERROR: Could not create temporary build directory. Exiting."
    exit 1
}

# Set proper permissions on the temporary directory
if [ -n "${BUILD_USER}" ]; then
    ${DOAS_CMD} chown -R "${BUILD_USER}:${BUILD_USER}" "${TMP_BUILD_DIR}" || {
        log_message "ERROR: Failed to set ownership on temporary build directory."
        exit 1
    }
    
    ${DOAS_CMD} chmod -R 755 "${TMP_BUILD_DIR}" || {
        log_message "ERROR: Failed to set permissions on temporary build directory."
        exit 1
    }
fi

# Create a temporary build file
TMP_BUILD_FILE="${TMP_BUILD_DIR}/${GO_EXECUTABLE_NAME}.tmp"
log_message "Using temporary build file: ${TMP_BUILD_FILE}"

# Set up Go cache directories if BUILD_USER is specified
if [ -n "${BUILD_USER}" ]; then
    # Create GOCACHE directory in the project directory
    GOCACHE_DIR="${PROJECT_DIR}/.gocache"
    log_message "Setting up GOCACHE directory: ${GOCACHE_DIR}"
    mkdir -p "${GOCACHE_DIR}" || {
        log_message "ERROR: Failed to create GOCACHE directory."
        exit 1
    }
    
    # Create GOMODCACHE directory in the project directory
    GOMODCACHE_DIR="${PROJECT_DIR}/.gomodcache"
    log_message "Setting up GOMODCACHE directory: ${GOMODCACHE_DIR}"
    mkdir -p "${GOMODCACHE_DIR}" || {
        log_message "ERROR: Failed to create GOMODCACHE directory."
        exit 1
    }
    
    # Set proper ownership
    ${DOAS_CMD} chown -R "${BUILD_USER}:${BUILD_USER}" "${GOCACHE_DIR}" "${GOMODCACHE_DIR}" || {
        log_message "ERROR: Failed to set ownership on Go cache directories."
        exit 1
    }
    
    # Set proper permissions
    ${DOAS_CMD} chmod -R 755 "${GOCACHE_DIR}" "${GOMODCACHE_DIR}" || {
        log_message "ERROR: Failed to set permissions on Go cache directories."
        exit 1
    }
    
    log_message "Go cache directories set up successfully."
    
    # Build the Go application with custom cache directories
    log_message "Building as user: ${BUILD_USER} with custom Go cache directories"
    build_output=$(${DOAS_CMD} -u "${BUILD_USER}" env GOCACHE="${GOCACHE_DIR}" GOMODCACHE="${GOMODCACHE_DIR}" ${GO_CMD} build -o "${TMP_BUILD_FILE}" . 2>&1)
    build_status=$?
else
    log_message "Building as current user"
    build_output=$(${GO_CMD} build -o "${TMP_BUILD_FILE}" . 2>&1)
    build_status=$?
fi

if [ ${build_status} -ne 0 ]; then
    log_message "ERROR: Build failed. Output: ${build_output}"
    exit 1
fi

log_message "Build successful."

# Create destination directory if needed
DEST_DIR=$(dirname "${GO_EXECUTABLE_DEST}")
if [ ! -d "${DEST_DIR}" ]; then
    log_message "Creating destination directory: ${DEST_DIR}"
    ${DOAS_CMD} mkdir -p "${DEST_DIR}"
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to create destination directory. Check permissions."
        rm -f "${TMP_BUILD_FILE}" # Clean up temporary file
        exit 1
    fi
fi

# Move the executable to the destination
log_message "Moving executable to ${GO_EXECUTABLE_DEST}..."
${DOAS_CMD} mv "${TMP_BUILD_FILE}" "${GO_EXECUTABLE_DEST}"
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to move executable to destination."
    rm -f "${TMP_BUILD_FILE}" # Try to clean up if move failed
    exit 1
fi

# Set proper permissions
log_message "Setting executable permissions..."
${DOAS_CMD} chmod 755 "${GO_EXECUTABLE_DEST}"
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to set executable permissions."
    exit 1
fi

log_message "Executable installed successfully at ${GO_EXECUTABLE_DEST}."

# --- Step 3: Create OpenRC service ---
log_message "Step 3: Creating OpenRC service..."

# Define service file path
SERVICE_FILE="/etc/init.d/${RC_SERVICE_NAME}"

# Determine working directory
WORKING_DIR="${SERVICE_WORKING_DIR:-${PROJECT_DIR}}"

# Create service content
SERVICE_CONTENT="#!/sbin/openrc-run

name=\"${RC_SERVICE_NAME}\"
description=\"${SERVICE_DESCRIPTION:-Go Application Service}\"

command=\"${GO_EXECUTABLE_DEST}\"
command_background=true

# Set the user to run the service as
${SERVICE_USER:+command_user=\"${SERVICE_USER}\"}

# Set the working directory
workdir=\"${WORKING_DIR}\"

# PID file
pidfile=\"/run/${RC_SERVICE_NAME}.pid\"

# Logging
output_log=\"/var/log/${RC_SERVICE_NAME}.log\"
error_log=\"/var/log/${RC_SERVICE_NAME}.err\"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f -m 0644 -o ${SERVICE_USER:-root} \"/var/log/${RC_SERVICE_NAME}.log\" \"/var/log/${RC_SERVICE_NAME}.err\"
}
"

# Write the service file
${DOAS_CMD} tee "${SERVICE_FILE}" > /dev/null << EOF
${SERVICE_CONTENT}
EOF

if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to create service file. Check permissions."
    exit 1
fi

# Set proper permissions on the service file
log_message "Setting permissions on service file..."
${DOAS_CMD} chmod 755 "${SERVICE_FILE}"
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to set permissions on service file."
    exit 1
fi

log_message "OpenRC service file created successfully at ${SERVICE_FILE}."

# --- Step 4: Start the service ---
log_message "Step 4: Starting service..."

# Start the service
log_message "Starting service: ${RC_SERVICE_NAME}"
${DOAS_CMD} ${RC_SERVICE_CMD} "${RC_SERVICE_NAME}" start
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to start service."
    log_message "Check service status with: ${DOAS_CMD} ${RC_SERVICE_CMD} ${RC_SERVICE_NAME} status"
    exit 1
fi

# Check if the service is running
sleep 2 # Give the service a moment to start
service_status=$(${DOAS_CMD} ${RC_SERVICE_CMD} "${RC_SERVICE_NAME}" status | grep -i "started")
if [ -z "${service_status}" ]; then
    log_message "WARNING: Service may not be running. Check logs."
    log_message "Check service logs at /var/log/${RC_SERVICE_NAME}.log and /var/log/${RC_SERVICE_NAME}.err"
    exit 1
fi

log_message "Service started successfully."

# --- Step 5: Enable the service to start on boot ---
log_message "Step 5: Enabling service to start on boot..."
${DOAS_CMD} rc-update add "${RC_SERVICE_NAME}" default
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to enable service for automatic start on boot."
    exit 1
fi

log_message "Service enabled to start on boot."

# --- Step 6: Generate doas permissions ---
log_message "Step 6: Generating doas permissions..."
"${SCRIPT_DIR}/generate_doas_permissions.sh"
if [ $? -ne 0 ]; then
    log_message "WARNING: Failed to generate doas permissions."
    log_message "You may need to manually set up doas permissions for the update script."
else
    log_message "doas permissions generated successfully."
    log_message "See the generated doas.txt file for instructions."
fi

# --- Summary ---
log_message "\n=== Initialization Complete ==="
log_message "Summary:"
log_message "- Repository cloned to: ${REPO_PATH}"
log_message "- Go application built from: ${PROJECT_DIR}"
log_message "- Executable installed at: ${GO_EXECUTABLE_DEST}"
log_message "- Service name: ${RC_SERVICE_NAME}"
log_message "- Service status: Running"
log_message "- Service enabled on boot: Yes"
log_message ""
log_message "To manage the service, use:"
log_message "  ${DOAS_CMD} ${RC_SERVICE_CMD} ${RC_SERVICE_NAME} start"
log_message "  ${DOAS_CMD} ${RC_SERVICE_CMD} ${RC_SERVICE_NAME} stop"
log_message "  ${DOAS_CMD} ${RC_SERVICE_CMD} ${RC_SERVICE_NAME} restart"
log_message "  ${DOAS_CMD} ${RC_SERVICE_CMD} ${RC_SERVICE_NAME} status"
log_message ""
log_message "To view service logs:"
log_message "  cat /var/log/${RC_SERVICE_NAME}.log"
log_message "  tail -f /var/log/${RC_SERVICE_NAME}.log  # Follow logs in real-time"
log_message ""
log_message "The update script is configured to automatically check for updates."
log_message "Make sure to install the doas permissions from doas.txt to enable automatic updates."
log_message ""
log_message "Initialization log saved to: ${LOG_FILE}"

exit 0