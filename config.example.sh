#!/bin/bash

# --- Configuration ---
# !!! IMPORTANT: Copy this file to config.sh and set these variables to match your environment !!!

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
