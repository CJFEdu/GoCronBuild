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
PROJECT_DIR="/path/to/your/go/project"

# The name of your Go application's main executable after building
# (e.g., if your main.go produces 'mygoserver', set this to 'mygoserver')
GO_EXECUTABLE_NAME="${PROJECT_NAME}-server"

# The full path where the compiled Go executable should be placed
# This is the path that your rc-service init script's 'command' variable points to.
# Example: GO_EXECUTABLE_DEST="/usr/local/bin/${GO_EXECUTABLE_NAME}"
GO_EXECUTABLE_DEST="/usr/local/bin/${GO_EXECUTABLE_NAME}"

# The name of your rc-service
SERVICE_NAME="${PROJECT_NAME}-service"
RC_SERVICE_NAME="${SERVICE_NAME}"

# Directory for all log files of this script
LOG_DIR="/var/log/${PROJECT_NAME}"
LOG_BASE_NAME="${PROJECT_NAME}-logs" # Base name for log files

# User to run git and go build commands as (if different from cron user)
# Leave empty if the cron user has direct permissions.
# If set, script will attempt to use 'sudo -u ${BUILD_USER}' for git and go commands.
# This user needs write access to PROJECT_DIR and GOCACHE, GOPATH if applicable.
BUILD_USER="${PROJECT_NAME}_builder" # e.g., "yourgouser"

# Git command (use absolute path if not in cron's default PATH)
GIT_CMD="/usr/bin/git" # Adjust if your git path is different

# Go command (use absolute path if not in cron's default PATH)
GO_CMD="/usr/bin/go" # Ubuntu typically installs Go in /usr/bin/go

# service command (use absolute path)
SERVICE_CMD="/usr/sbin/service" # Ubuntu uses systemd's service command
RC_SERVICE_CMD="/sbin/rc-service" # Alpine uses rc-service

# sudo command (use absolute path)
DOAS_CMD="/usr/bin/doas" # Alpine uses doas instead of sudo
SUDO_CMD="/usr/bin/sudo" # Ubuntu uses sudo instead of doas
