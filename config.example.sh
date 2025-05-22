#!/bin/bash

# --- Configuration ---
# !!! IMPORTANT: Copy this file to config.sh and set these variables to match your environment !!!


# --- Project Name ---
# Only used in this config to expedite filling out the rest of the variables
PROJECT_NAME="yourproject"

# --- Repository Configuration ---
# Git repository URL to clone (required for initialize_go_server.sh)
GIT_REPO_URL="https://github.com/yourusername/yourrepo.git"

# Git branch to use (required for initialize_go_server.sh)
GIT_BRANCH="main"

# --- Service Configuration ---
# User to run the service as (required for initialize_go_server.sh)
SERVICE_USER="$(whoami)"

# Description for the systemd service (required for initialize_go_server.sh)
SERVICE_DESCRIPTION="${PROJECT_NAME} Service"

# Working directory for the service (defaults to PROJECT_DIR if not set)
SERVICE_WORKING_DIR=""

# Full path to your Go project's Git repository
REPO_PATH="/path/to/your/go/project"

# Full path to your Go project's source code
PROJECT_DIR="${REPO_PATH}/src"

# The name of your Go application's main executable after building
# (e.g., if your main.go produces 'mygoserver', set this to 'mygoserver')
GO_EXECUTABLE_NAME="${PROJECT_NAME}-server"

# The full path where the compiled Go executable should be placed
# This is the path that your rc-service init script's 'command' variable points to.
# Example: GO_EXECUTABLE_DEST="/usr/local/bin/${GO_EXECUTABLE_NAME}"
GO_EXECUTABLE_DEST="/usr/local/bin/${GO_EXECUTABLE_NAME}"

# The name of your systemd service
SERVICE_NAME="${PROJECT_NAME}-service"

# Directory for all log files of this script
LOG_DIR="/var/log/${PROJECT_NAME}_updater"
LOG_BASE_NAME="${PROJECT_NAME}-logs" # Base name for log files

# User to run git and go build commands as (if different from cron user)
# Leave empty if the cron user has direct permissions.
# If set, script will attempt to use 'sudo -u ${BUILD_USER}' for git and go commands.
# This user needs write access to PROJECT_DIR and GOCACHE, GOPATH if applicable.
BUILD_USER="${PROJECT_NAME}_builder" # e.g., "yourgouser"
BUILD_GROUP="${PROJECT_NAME}_group" # e.g., "yourgouser"

# Git command (use absolute path if not in cron's default PATH)
GIT_CMD="/usr/bin/git" # Adjust if your git path is different

# Go command (use absolute path if not in cron's default PATH)
GO_CMD="/usr/bin/go" # Ubuntu typically installs Go in /usr/bin/go

# systemd service command (use absolute path)
SERVICE_CMD="/bin/systemctl" # Ubuntu uses systemd's systemctl command

# sudo command (use absolute path)
SUDO_CMD="/usr/bin/sudo" # Ubuntu uses sudo for privilege escalation
