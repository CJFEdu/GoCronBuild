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
OUTPUT_FILE="${SCRIPT_DIR}/sudoers.txt"
> "${OUTPUT_FILE}"  # Clear the file if it exists

# Function to add a line to the output file
add_line() {
    echo "$1" >> "${OUTPUT_FILE}"
}

# Add header
add_line "# Sudoers entries for GoCronBuild"
add_line "# Generated on $(date '+%Y-%m-%d %H:%M:%S')"
add_line "# For user: ${CURRENT_USER}"
add_line ""
add_line "# WARNING: Always use 'visudo' to edit sudoers files to avoid syntax errors"
add_line "# that could lock you out of the system."
add_line ""

# Add current user to BUILD_GROUP if it exists
if [ -n "${BUILD_GROUP}" ]; then
    echo "Checking if current user ${CURRENT_USER} is in group ${BUILD_GROUP}..."
    if groups ${CURRENT_USER} | grep -q "\b${BUILD_GROUP}\b"; then
        echo "User ${CURRENT_USER} is already in group ${BUILD_GROUP}."
    else
        echo "Adding user ${CURRENT_USER} to group ${BUILD_GROUP}..."
        sudo usermod -a -G "${BUILD_GROUP}" "${CURRENT_USER}"
        if [ $? -eq 0 ]; then
            echo "Successfully added ${CURRENT_USER} to group ${BUILD_GROUP}."
            echo "NOTE: You will need to log out and log back in for the group changes to take effect."
            
            # Add a comment to the output file
            add_line "# NOTE: User ${CURRENT_USER} has been added to the ${BUILD_GROUP} group"
            add_line "# You will need to log out and log back in for the group changes to take effect"
            add_line ""
        else
            echo "Failed to add ${CURRENT_USER} to group ${BUILD_GROUP}."
            echo "You may need to run this script with sudo privileges."
            
            # Add a comment to the output file
            add_line "# WARNING: Failed to add ${CURRENT_USER} to the ${BUILD_GROUP} group"
            add_line "# Run: sudo usermod -a -G ${BUILD_GROUP} ${CURRENT_USER}"
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
add_line "${CURRENT_USER} ALL=(root) NOPASSWD: ${RC_SERVICE_CMD} ${RC_SERVICE_NAME} restart"
add_line ""

# File operations permissions
add_line "# Allow moving the executable to backup"
add_line "${CURRENT_USER} ALL=(root) NOPASSWD: /usr/bin/mv ${GO_EXECUTABLE_DEST} ${GO_EXECUTABLE_DEST}.bak_*"
add_line ""

add_line "# Allow moving the new executable into place"
add_line "${CURRENT_USER} ALL=(root) NOPASSWD: /usr/bin/mv ${GO_EXECUTABLE_DEST}.tmp.* ${GO_EXECUTABLE_DEST}"
add_line ""

add_line "# Allow deleting backup executables"
add_line "${CURRENT_USER} ALL=(root) NOPASSWD: /usr/bin/rm ${GO_EXECUTABLE_DEST}.bak_*"
add_line ""

# If BUILD_USER is set, add permissions for it
if [ -n "${BUILD_USER}" ]; then
    add_line "# Allow running git and go commands as ${BUILD_USER}"
    add_line "${CURRENT_USER} ALL=(${BUILD_USER}) NOPASSWD: ${GIT_CMD} pull"
    add_line "${CURRENT_USER} ALL=(${BUILD_USER}) NOPASSWD: ${GO_CMD} build -o * ."
    add_line ""
fi

# Add entries for manual execution
add_line "# === Alternative entries for manual execution ==="
add_line "# These entries allow you to run the commands with a password prompt"
add_line "# Useful for testing or one-off manual execution"
add_line ""

# Service restart permission
add_line "# Allow restarting the service"
add_line "${CURRENT_USER} ALL=(root) ${RC_SERVICE_CMD} ${RC_SERVICE_NAME} restart"
add_line ""

# File operations permissions
add_line "# Allow moving the executable to backup"
add_line "${CURRENT_USER} ALL=(root) /usr/bin/mv ${GO_EXECUTABLE_DEST} ${GO_EXECUTABLE_DEST}.bak_*"
add_line ""

add_line "# Allow moving the new executable into place"
add_line "${CURRENT_USER} ALL=(root) /usr/bin/mv ${GO_EXECUTABLE_DEST}.tmp.* ${GO_EXECUTABLE_DEST}"
add_line ""

add_line "# Allow deleting backup executables"
add_line "${CURRENT_USER} ALL=(root) /usr/bin/rm ${GO_EXECUTABLE_DEST}.bak_*"
add_line ""

# If BUILD_USER is set, add permissions for it
if [ -n "${BUILD_USER}" ]; then
    add_line "# Allow running git and go commands as ${BUILD_USER}"
    add_line "${CURRENT_USER} ALL=(${BUILD_USER}) ${GIT_CMD} pull"
    add_line "${CURRENT_USER} ALL=(${BUILD_USER}) ${GO_CMD} build -o * ."
    add_line ""
fi

add_line "# === Installation Instructions ==="
add_line "# IMPORTANT: Always use 'visudo' to edit sudoers files to avoid syntax errors"
add_line "# that could lock you out of the system."
add_line ""
add_line "# Create a dedicated sudoers file with:"
add_line "# sudo visudo -f /etc/sudoers.d/gocronbuild"
add_line ""
add_line "# Copy the appropriate entries above to this file"
add_line "# For automated execution (cron jobs), use the 'NOPASSWD' entries"
add_line "# For manual testing, you can use either set of entries"
add_line ""
add_line "# After creating the file, ensure it has the correct permissions:"
add_line "# sudo chmod 440 /etc/sudoers.d/gocronbuild"
add_line ""
add_line "# To verify the sudoers syntax, use:"
add_line "# sudo visudo -c -f /etc/sudoers.d/gocronbuild"

echo "Sudoers entries have been generated in ${OUTPUT_FILE}"
echo "Review the file and add the appropriate entries to /etc/sudoers.d/gocronbuild"
echo "IMPORTANT: Always use 'visudo' to edit sudoers files to avoid syntax errors"
echo "           that could lock you out of the system."
echo ""
echo "To create a dedicated sudoers file:"
echo "  sudo visudo -f /etc/sudoers.d/gocronbuild"
echo ""
echo "After creating the file, ensure it has the correct permissions:"
echo "  sudo chmod 440 /etc/sudoers.d/gocronbuild"
