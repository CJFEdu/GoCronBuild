#!/bin/bash

# --- Initialize Go Server Script ---
# This script automates the process of setting up a Go application on Ubuntu:
# 1. Clones the Git repository
# 2. Builds the Go application
# 3. Creates a systemd service
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

check_var "GIT_REPO_URL" "${GIT_REPO_URL}"
check_var "GIT_BRANCH" "${GIT_BRANCH}"
check_var "SERVICE_USER" "${SERVICE_USER}"
check_var "REPO_PATH" "${REPO_PATH}"
check_var "PROJECT_DIR" "${PROJECT_DIR}"
check_var "GO_EXECUTABLE_NAME" "${GO_EXECUTABLE_NAME}"
check_var "GO_EXECUTABLE_DEST" "${GO_EXECUTABLE_DEST}"
check_var "RC_SERVICE_NAME" "${RC_SERVICE_NAME}"
check_var "LOG_DIR" "${LOG_DIR}"
check_var "LOG_BASE_NAME" "${LOG_BASE_NAME}"
check_var "SERVICE_DESCRIPTION" "${SERVICE_DESCRIPTION}"

if [ ${MISSING_VARS} -gt 0 ]; then
    log_message "ERROR: ${MISSING_VARS} required variables are missing. Please update your config.sh"
    exit 1
fi

# Set SERVICE_WORKING_DIR to PROJECT_DIR if not specified
if [ -z "${SERVICE_WORKING_DIR}" ]; then
    SERVICE_WORKING_DIR="${PROJECT_DIR}"
    log_message "SERVICE_WORKING_DIR not set, using PROJECT_DIR: ${PROJECT_DIR}"
fi

# --- Step 1: Clone the Git repository ---
log_message "Step 1: Cloning Git repository from ${GIT_REPO_URL} (branch: ${GIT_BRANCH})..."

# Check if REPO_PATH already exists
if [ -d "${REPO_PATH}" ]; then
    log_message "WARNING: Repository directory ${REPO_PATH} already exists."
    read -p "Do you want to remove it and start fresh? (y/n): " -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_message "Removing existing repository directory..."
        rm -rf "${REPO_PATH}"
        log_message "Directory removed."
    else
        log_message "Using existing directory."
        if [ ! -d "${REPO_PATH}/.git" ]; then
            log_message "ERROR: Existing directory is not a Git repository. Please remove it or specify a different REPO_PATH."
            exit 1
        fi
    fi
fi

# Create parent directory if needed
PARENT_DIR=$(dirname "${REPO_PATH}")
if [ ! -d "${PARENT_DIR}" ]; then
    log_message "Creating parent directory: ${PARENT_DIR}"
    mkdir -p "${PARENT_DIR}" || {
        log_message "ERROR: Failed to create parent directory. Exiting."
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

# Clone the repository if it doesn't exist
log_message "Cloning repository..."
if [ ! -d "${REPO_PATH}" ]; then
    log_message "Cloning from ${GIT_REPO_URL} (branch: ${GIT_BRANCH})..."
    
    # Create directory with appropriate permissions
    if [ -n "${BUILD_USER}" ]; then
        log_message "Creating directory with permissions for BUILD_USER: ${BUILD_USER}"
        mkdir -p "${PARENT_DIR}" || {
            log_message "ERROR: Failed to create parent directory. Exiting."
            exit 1
        }
        
        # Clone the repository as BUILD_USER
        log_message "Cloning repository as ${BUILD_USER}..."
        git_clone_output=$(${SUDO_CMD} -u "${BUILD_USER}" ${GIT_CMD} clone -b "${GIT_BRANCH}" "${GIT_REPO_URL}" "${REPO_PATH}" 2>&1)
    else
        log_message "Cloning repository as current user..."
        git_clone_output=$(${GIT_CMD} clone -b "${GIT_BRANCH}" "${GIT_REPO_URL}" "${REPO_PATH}" 2>&1)
    fi
    
    # Check if clone was successful
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to clone repository. Output:\n${git_clone_output}"
        exit 1
    fi
    log_message "Repository cloned successfully to ${REPO_PATH}"
else
    log_message "Repository directory already exists. Skipping clone."
    cd "${REPO_PATH}" || {
        log_message "ERROR: Could not navigate to repository directory ${REPO_PATH}. Exiting."
        exit 1
    }
    
    # Update the repository
    log_message "Updating existing repository..."
    if [ -n "${BUILD_USER}" ]; then
        git_pull_output=$(${SUDO_CMD} -u "${BUILD_USER}" ${GIT_CMD} pull 2>&1)
    else
        git_pull_output=$(${GIT_CMD} pull 2>&1)
    fi
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to update repository. Output:\n${git_pull_output}"
        exit 1
    fi
    log_message "Repository updated successfully."
fi

# --- Step 2: Build the Go application ---
log_message "Step 2: Building Go application..."
cd "${PROJECT_DIR}" || {
    log_message "ERROR: Could not navigate to project directory ${PROJECT_DIR}. Exiting."
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
    ${SUDO_CMD} chown -R "${BUILD_USER}:${BUILD_USER}" "${TMP_BUILD_DIR}" || {
        log_message "ERROR: Failed to set ownership on temporary build directory."
        exit 1
    }
    ${SUDO_CMD} chmod -R 755 "${TMP_BUILD_DIR}" || {
        log_message "ERROR: Failed to set permissions on temporary build directory."
        exit 1
    }
}

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
    ${SUDO_CMD} chown -R "${BUILD_USER}:${BUILD_USER}" "${GOCACHE_DIR}" "${GOMODCACHE_DIR}" || {
        log_message "ERROR: Failed to set ownership on Go cache directories."
        exit 1
    }
    
    # Set proper permissions
    ${SUDO_CMD} chmod -R 755 "${GOCACHE_DIR}" "${GOMODCACHE_DIR}" || {
        log_message "ERROR: Failed to set permissions on Go cache directories."
        exit 1
    }
    
    log_message "Go cache directories set up successfully."
    
    # Build the Go application with custom cache directories
    log_message "Building as user: ${BUILD_USER} with custom Go cache directories"
    build_output=$(${SUDO_CMD} -u "${BUILD_USER}" env GOCACHE="${GOCACHE_DIR}" GOMODCACHE="${GOMODCACHE_DIR}" ${GO_CMD} build -o "${TMP_BUILD_FILE}" . 2>&1)
    build_status=$?
else
    # Build the Go application normally
    build_output=$(${GO_CMD} build -o "${TMP_BUILD_FILE}" . 2>&1)
    build_status=$?
fi

if [ ${build_status} -ne 0 ]; then
    log_message "ERROR: Go build failed with status ${build_status}."
    log_message "Build output: ${build_output}"
    rm -f "${TMP_BUILD_FILE}" # Clean up temporary file on build failure
    exit 1
fi
log_message "Go application built successfully to temporary file: ${TMP_BUILD_FILE}"

# Create the destination directory if it doesn't exist
DEST_DIR=$(dirname "${GO_EXECUTABLE_DEST}")
if [ ! -d "${DEST_DIR}" ]; then
    log_message "Creating destination directory: ${DEST_DIR}"
    ${SUDO_CMD} mkdir -p "${DEST_DIR}"
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to create destination directory. Check permissions."
        rm -f "${TMP_BUILD_FILE}" # Clean up temporary file
        exit 1
    fi
fi

# Move the executable to the destination
log_message "Moving executable to ${GO_EXECUTABLE_DEST}..."
${SUDO_CMD} mv "${TMP_BUILD_FILE}" "${GO_EXECUTABLE_DEST}"
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to move executable to destination."
    rm -f "${TMP_BUILD_FILE}" # Try to clean up if move failed
    exit 1
fi

# Set proper permissions
log_message "Setting executable permissions..."
${SUDO_CMD} chmod 755 "${GO_EXECUTABLE_DEST}"
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to set executable permissions."
    exit 1
fi

# --- Step 3: Create systemd service ---
log_message "Step 3: Creating systemd service..."

# Create the service file
SERVICE_FILE="/etc/systemd/system/${RC_SERVICE_NAME}.service"
log_message "Creating service file: ${SERVICE_FILE}"

# Create the service file content
SERVICE_CONTENT="[Unit]
Description=${SERVICE_DESCRIPTION}
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${SERVICE_WORKING_DIR}
ExecStart=${GO_EXECUTABLE_DEST}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"

# Write the service file
echo "${SERVICE_CONTENT}" | ${SUDO_CMD} tee "${SERVICE_FILE}" > /dev/null
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to create service file. Check permissions."
    exit 1
fi

log_message "Service file created successfully"

# --- Step 4: Start the service ---
log_message "Step 4: Starting the service..."

# Reload systemd to recognize the new service
log_message "Reloading systemd daemon..."
${SUDO_CMD} systemctl daemon-reload
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to reload systemd daemon."
    exit 1
fi

# Start the service
log_message "Starting service: ${RC_SERVICE_NAME}"
${SUDO_CMD} systemctl start "${RC_SERVICE_NAME}"
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to start service."
    log_message "Check service status with: ${SUDO_CMD} systemctl status ${RC_SERVICE_NAME}"
    exit 1
fi

# Check service status
sleep 2 # Give the service a moment to start
service_status=$(${SUDO_CMD} systemctl is-active "${RC_SERVICE_NAME}")
if [ "${service_status}" != "active" ]; then
    log_message "WARNING: Service is not active. Status: ${service_status}"
    log_message "Check service logs with: ${SUDO_CMD} journalctl -u ${RC_SERVICE_NAME}"
    exit 1
fi

log_message "Service started successfully"

# --- Step 5: Enable the service to start on boot ---
log_message "Step 5: Enabling service to start on boot..."
${SUDO_CMD} systemctl enable "${RC_SERVICE_NAME}"
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to enable service for automatic start on boot."
    exit 1
fi

log_message "Service enabled for automatic start on boot"

# --- Step 6: Set up update script permissions ---
log_message "Step 6: Setting up permissions for update script..."

# Generate sudo permissions
log_message "Generating sudo permissions..."
"${SCRIPT_DIR}/generate_sudo_permissions.sh"
if [ $? -ne 0 ]; then
    log_message "WARNING: Failed to generate sudo permissions."
    log_message "You may need to manually set up sudo permissions for the update script."
else
    log_message "Sudo permissions generated. Please review and install them manually."
    log_message "See the generated sudoers.txt file for instructions."
fi

# --- Final Summary ---
log_message "=== Initialization Complete ==="
log_message "Summary of initialization:"
log_message "- Repository cloned to: ${REPO_PATH}"
log_message "- Go application built from: ${PROJECT_DIR}"
log_message "- Executable installed at: ${GO_EXECUTABLE_DEST}"
log_message "- Service name: ${RC_SERVICE_NAME}"
log_message "- Service status: $(${SUDO_CMD} systemctl is-active "${RC_SERVICE_NAME}")"
log_message "- Service enabled on boot: $(${SUDO_CMD} systemctl is-enabled "${RC_SERVICE_NAME}")"
log_message ""
log_message "To manage the service, use:"
log_message "  ${SUDO_CMD} systemctl start ${RC_SERVICE_NAME}"
log_message "  ${SUDO_CMD} systemctl stop ${RC_SERVICE_NAME}"
log_message "  ${SUDO_CMD} systemctl restart ${RC_SERVICE_NAME}"
log_message "  ${SUDO_CMD} systemctl status ${RC_SERVICE_NAME}"
log_message ""
log_message "To view service logs:"
log_message "  ${SUDO_CMD} journalctl -u ${RC_SERVICE_NAME}"
log_message "  ${SUDO_CMD} journalctl -u ${RC_SERVICE_NAME} -f  # Follow logs in real-time"
log_message ""
log_message "The update script is configured to automatically check for updates."
log_message "Make sure to install the ${SUDO_CMD} permissions from sudoers.txt to enable automatic updates."
log_message ""
log_message "Initialization log saved to: ${LOG_FILE}"

exit 0
