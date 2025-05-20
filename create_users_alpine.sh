#!/bin/bash

# Script to create necessary users for GoCronBuild on Alpine Linux
# This script creates BUILD_USER and SERVICE_USER from config.sh if they don't exist
# and sets up appropriate permissions

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check if script is run with doas/root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run with doas privileges."
    echo "Please run: doas $0"
    exit 1
fi

# Check if config.sh exists and source it
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
else
    echo "Error: Configuration file ${CONFIG_FILE} not found."
    echo "Please copy config.example.sh to config.sh and update the values."
    exit 1
fi

# Function to create a user if it doesn't exist
create_user_if_needed() {
    local username=$1
    local create_home=$2  # "yes" or "no"
    local system_user=$3  # "yes" or "no"
    
    if [ -z "$username" ]; then
        echo "Skipping user creation: Username is empty"
        return 0
    fi
    
    # Check if user already exists
    if id "$username" &>/dev/null; then
        echo "User '$username' already exists. Skipping creation."
    else
        echo "Creating user '$username'..."
        
        local cmd="adduser"
        local options=""
        
        # Add options based on parameters
        if [ "$create_home" = "no" ]; then
            options="$options -H"  # Don't create home directory
        fi
        
        if [ "$system_user" = "yes" ]; then
            options="$options -S"  # Create system user
        fi
        
        # Create the user with no login shell if it's a system user
        if [ "$system_user" = "yes" ]; then
            options="$options -s /sbin/nologin"
        fi
        
        # Alpine uses adduser with different options than Ubuntu's useradd
        $cmd $options "$username"
        
        if [ $? -eq 0 ]; then
            echo "User '$username' created successfully."
        else
            echo "Failed to create user '$username'."
            exit 1
        fi
    fi
}

# Function to set up project directory permissions
setup_project_permissions() {
    local username=$1
    
    if [ -z "$username" ] || [ -z "${PROJECT_DIR}" ]; then
        return 0
    fi
    
    echo "Setting up project directory permissions for $username..."
    
    # Create project directory if it doesn't exist
    if [ ! -d "${PROJECT_DIR}" ]; then
        echo "Creating project directory: ${PROJECT_DIR}"
        mkdir -p "${PROJECT_DIR}"
        if [ $? -ne 0 ]; then
            echo "Failed to create project directory."
            exit 1
        fi
    fi
    
    # Set ownership
    chown -R "$username:$username" "${PROJECT_DIR}"
    if [ $? -ne 0 ]; then
        echo "Failed to set ownership on project directory."
        exit 1
    fi
    
    # Set permissions (750 allows the owner full access, group read/execute, others nothing)
    chmod -R 750 "${PROJECT_DIR}"
    if [ $? -ne 0 ]; then
        echo "Failed to set permissions on project directory."
        exit 1
    fi
    
    echo "Project directory permissions set successfully."
}

# Function to set up service user
setup_service_user() {
    local username=$1
    
    if [ -z "$username" ]; then
        return 0
    fi
    
    echo "Setting up service user '$username'..."
    
    # Create service directory if specified
    if [ -n "${SERVICE_WORKING_DIR}" ] && [ "${SERVICE_WORKING_DIR}" != "${PROJECT_DIR}" ]; then
        if [ ! -d "${SERVICE_WORKING_DIR}" ]; then
            echo "Creating service working directory: ${SERVICE_WORKING_DIR}"
            mkdir -p "${SERVICE_WORKING_DIR}"
            if [ $? -ne 0 ]; then
                echo "Failed to create service working directory."
                exit 1
            fi
        fi
        
        # Set ownership of service directory
        chown -R "$username:$username" "${SERVICE_WORKING_DIR}"
        if [ $? -ne 0 ]; then
            echo "Failed to set ownership on service working directory."
            exit 1
        fi
        
        # Set permissions
        chmod -R 750 "${SERVICE_WORKING_DIR}"
        if [ $? -ne 0 ]; then
            echo "Failed to set permissions on service working directory."
            exit 1
        fi
    fi
    
    # Ensure the executable destination directory exists
    if [ -n "${GO_EXECUTABLE_DEST}" ]; then
        local exec_dir=$(dirname "${GO_EXECUTABLE_DEST}")
        if [ ! -d "$exec_dir" ]; then
            echo "Creating executable directory: $exec_dir"
            mkdir -p "$exec_dir"
            if [ $? -ne 0 ]; then
                echo "Failed to create executable directory."
                exit 1
            fi
        fi
    fi
    
    echo "Service user setup completed."
}

# Function to set up build user
setup_build_user() {
    local username=$1
    
    if [ -z "$username" ]; then
        return 0
    fi
    
    echo "Setting up build user '$username'..."
    
    # Create Go cache directories in the project
    if [ -n "${PROJECT_DIR}" ]; then
        local gocache_dir="${PROJECT_DIR}/.gocache"
        local gomodcache_dir="${PROJECT_DIR}/.gomodcache"
        
        echo "Creating Go cache directories..."
        mkdir -p "$gocache_dir" "$gomodcache_dir"
        
        # Set ownership
        chown -R "$username:$username" "$gocache_dir" "$gomodcache_dir"
        
        # Set permissions
        chmod -R 750 "$gocache_dir" "$gomodcache_dir"
    fi
    
    echo "Build user setup completed."
}

# Main execution
echo "=== GoCronBuild User Setup for Alpine Linux ==="

# Create BUILD_USER if specified
if [ -n "${BUILD_USER}" ]; then
    echo "\nSetting up BUILD_USER: ${BUILD_USER}"
    create_user_if_needed "${BUILD_USER}" "no" "yes"
    setup_build_user "${BUILD_USER}"
    setup_project_permissions "${BUILD_USER}"
else
    echo "\nBUILD_USER not specified in config.sh. Skipping."
fi

# Create SERVICE_USER if specified and different from BUILD_USER
if [ -n "${SERVICE_USER}" ] && [ "${SERVICE_USER}" != "${BUILD_USER}" ]; then
    echo "\nSetting up SERVICE_USER: ${SERVICE_USER}"
    create_user_if_needed "${SERVICE_USER}" "no" "yes"
    setup_service_user "${SERVICE_USER}"
else
    if [ -n "${SERVICE_USER}" ]; then
        echo "\nSERVICE_USER is the same as BUILD_USER or not specified. Using existing user."
        setup_service_user "${SERVICE_USER}"
    else
        echo "\nSERVICE_USER not specified in config.sh. Skipping."
    fi
fi

echo "\n=== User Setup Complete ==="
echo "You may need to add these users to the doas configuration with appropriate permissions."
echo "Run ./generate_doas_permissions.sh to generate the necessary doas permissions."

exit 0