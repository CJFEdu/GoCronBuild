#!/bin/bash

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

# Get the current user
CURRENT_USER=$(whoami)

# Create the output file
OUTPUT_FILE="${SCRIPT_DIR}/doas.txt"
> "${OUTPUT_FILE}"  # Clear the file if it exists

# Function to add a line to the output file
add_line() {
    echo "$1" >> "${OUTPUT_FILE}"
}

# Add header
add_line "# doas.conf entries for GoCronBuild"
add_line "# Generated on $(date '+%Y-%m-%d %H:%M:%S')"
add_line "# For user: ${CURRENT_USER}"
add_line ""

# Add current user to BUILD_GROUP if it exists
if [ -n "${BUILD_GROUP}" ]; then
    echo "Checking if current user ${CURRENT_USER} is in group ${BUILD_GROUP}..."
    if groups ${CURRENT_USER} | grep -q "\b${BUILD_GROUP}\b"; then
        echo "User ${CURRENT_USER} is already in group ${BUILD_GROUP}."
    else
        echo "Adding user ${CURRENT_USER} to group ${BUILD_GROUP}..."
        doas adduser "${CURRENT_USER}" "${BUILD_GROUP}"
        if [ $? -eq 0 ]; then
            echo "Successfully added ${CURRENT_USER} to group ${BUILD_GROUP}."
            echo "NOTE: You will need to log out and log back in for the group changes to take effect."
            
            # Add a comment to the output file
            add_line "# NOTE: User ${CURRENT_USER} has been added to the ${BUILD_GROUP} group"
            add_line "# You will need to log out and log back in for the group changes to take effect"
            add_line ""
        else
            echo "Failed to add ${CURRENT_USER} to group ${BUILD_GROUP}."
            echo "You may need to run this script with doas privileges."
            
            # Add a comment to the output file
            add_line "# WARNING: Failed to add ${CURRENT_USER} to the ${BUILD_GROUP} group"
            add_line "# Run: doas adduser ${CURRENT_USER} ${BUILD_GROUP}"
            add_line ""
        fi
    fi
fi

# Add entries for cron user
add_line "# === Entries for cron/automated execution ==="
add_line "# These entries allow the script to run without password prompts"
add_line ""

# Service restart permission
add_line "# Allow restarting the service"
add_line "permit nopass ${CURRENT_USER} as root cmd ${RC_SERVICE_CMD} args ${RC_SERVICE_NAME} restart"
add_line ""

# File operations permissions
add_line "# Allow moving the executable to backup"
add_line "permit nopass ${CURRENT_USER} as root cmd /usr/bin/mv args ${GO_EXECUTABLE_DEST} ${GO_EXECUTABLE_DEST}.bak_*"
add_line ""

add_line "# Allow moving the new executable into place"
add_line "permit nopass ${CURRENT_USER} as root cmd /usr/bin/mv args ${GO_EXECUTABLE_DEST}.tmp.* ${GO_EXECUTABLE_DEST}"
add_line ""

add_line "# Allow deleting backup executables"
add_line "permit nopass ${CURRENT_USER} as root cmd /usr/bin/rm args ${GO_EXECUTABLE_DEST}.bak_*"
add_line ""

# Add permissions for log directory
add_line "# Allow creating and writing to log directory"
add_line "permit nopass ${CURRENT_USER} as root cmd /bin/mkdir args -p ${LOG_DIR}"
add_line "permit nopass ${CURRENT_USER} as root cmd /bin/chmod args -R 755 ${LOG_DIR}"
# For doas, we need to handle the user:group differently
# We'll use a variable to store the user:group string to avoid syntax issues
add_line "# Define user:group string for chown"
add_line "USER_GROUP_STRING=\"${CURRENT_USER}:${CURRENT_USER}\""
add_line "permit nopass ${CURRENT_USER} as root cmd /bin/chown args -R \$USER_GROUP_STRING ${LOG_DIR}"
add_line ""

# If BUILD_USER is set, add permissions for it
if [ -n "${BUILD_USER}" ]; then
    add_line "# Allow running git and go commands as ${BUILD_USER}"
    add_line "permit nopass ${CURRENT_USER} as ${BUILD_USER} cmd ${GIT_CMD} args pull"
    add_line "permit nopass ${CURRENT_USER} as ${BUILD_USER} cmd ${GIT_CMD} args rev-parse HEAD"
    add_line "permit nopass ${CURRENT_USER} as ${BUILD_USER} cmd ${GO_CMD} args build -o * ."
    add_line ""
fi

# Add entries for manual execution
add_line "# === Alternative entries for manual execution ==="
add_line "# These entries allow you to run the commands with a password prompt"
add_line "# Useful for testing or one-off manual execution"
add_line ""

# Service restart permission
add_line "# Allow restarting the service"
add_line "permit ${CURRENT_USER} as root cmd ${RC_SERVICE_CMD} args ${RC_SERVICE_NAME} restart"
add_line ""

# File operations permissions
add_line "# Allow moving the executable to backup"
add_line "permit ${CURRENT_USER} as root cmd /usr/bin/mv args ${GO_EXECUTABLE_DEST} ${GO_EXECUTABLE_DEST}.bak_*"
add_line ""

add_line "# Allow moving the new executable into place"
add_line "permit ${CURRENT_USER} as root cmd /usr/bin/mv args ${GO_EXECUTABLE_DEST}.tmp.* ${GO_EXECUTABLE_DEST}"
add_line ""

add_line "# Allow deleting backup executables"
add_line "permit ${CURRENT_USER} as root cmd /usr/bin/rm args ${GO_EXECUTABLE_DEST}.bak_*"
add_line ""

# Add permissions for log directory (with password)
add_line "# Allow creating and writing to log directory"
add_line "permit ${CURRENT_USER} as root cmd /bin/mkdir args -p ${LOG_DIR}"
add_line "permit ${CURRENT_USER} as root cmd /bin/chmod args -R 755 ${LOG_DIR}"
add_line "permit ${CURRENT_USER} as root cmd /bin/chown args -R \$USER_GROUP_STRING ${LOG_DIR}"
add_line ""

# If BUILD_USER is set, add permissions for it
if [ -n "${BUILD_USER}" ]; then
    add_line "# Allow running git and go commands as ${BUILD_USER}"
    add_line "permit ${CURRENT_USER} as ${BUILD_USER} cmd ${GIT_CMD} args pull"
    add_line "permit ${CURRENT_USER} as ${BUILD_USER} cmd ${GIT_CMD} args rev-parse HEAD"
    add_line "permit ${CURRENT_USER} as ${BUILD_USER} cmd ${GO_CMD} args build -o * ."
    add_line ""
fi

add_line "# === Installation Instructions ==="
add_line "# Copy the appropriate entries above to /etc/doas.conf"
add_line "# For automated execution (cron jobs), use the 'nopass' entries"
add_line "# For manual testing, you can use either set of entries"
add_line ""
add_line "# After modifying /etc/doas.conf, verify the syntax with:"
add_line "# doas -C /etc/doas.conf"

echo "doas.conf entries have been generated in ${OUTPUT_FILE}"
echo "Review the file and add the appropriate entries to your /etc/doas.conf"
