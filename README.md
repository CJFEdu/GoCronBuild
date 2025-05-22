# Go Cron Build for Ubuntu

This shell script automates the process of updating a Go application deployed on Ubuntu systems. It is designed to run as a cron job to periodically check for updates in a Git repository, rebuild the Go application if changes are found, and then restart the corresponding systemd service.

**Note:** This script is specifically designed for Ubuntu systems. For the Alpine Linux version, please see the README_ALPINE.md file.

## Features

* **Git Integration**: Pulls the latest changes from a specified Git repository.
* **Conditional Rebuild**: Only rebuilds the Go application if new commits are pulled.
* **Safe Updates**:
    * Builds the new executable to a temporary file.
    * If the build is successful, it backs up the current live executable.
    * Moves the newly built executable into the live location.
* **Service Restart**: Restarts the specified systemd service after a successful update.
* **Rollback on Restart Failure**: If the service fails to restart with the new executable, it attempts to move the backup executable back into place and restart the service again.
* **Logging**:
    * Maintains daily log files (e.g., `go_project_updater_YYYY-MM-DD.log`).
    * Automatically cleans up log files older than 90 days.
* **Backup Management**:
    * Creates a timestamped backup of the live executable before replacing it (e.g., `yourgoserver.bak_YYYYMMDDHHMMSS`).
    * Deletes the backup created during the current run if the service restarts successfully with the new version.
* **Ubuntu Integration**: Uses `sudo` for privilege escalation and `systemd` for service management.

## Prerequisites

Before using this script on Ubuntu, ensure the following are installed and configured:

1. **Git**: (`/usr/bin/git` or as configured in the script)
2. **Go**: (`/usr/bin/go` or as configured in the script)
3. **sudo**: (pre-installed on Ubuntu)
   * The user running the cron job (or the `BUILD_USER` if specified) must have `sudo` permissions configured.
   * The script uses the `-n` flag with all sudo commands to prevent password prompts. This ensures the script can run unattended, but requires that the `NOPASSWD` option is correctly configured in sudoers.
4. **An existing Go project managed with Git.**
5. **systemd** (pre-installed on Ubuntu) for service management.

## Configuration

The script uses an external configuration file (`config.sh`) to store all environment-specific settings. A template file (`config.example.sh`) is provided that you should copy and customize:

1. Copy the example configuration file to create your own configuration:
   ```bash
   cp config.example.sh config.sh
   ```

2. Edit `config.sh` and modify these variables to match your environment:
   * `GIT_REPO_URL`: Git repository URL to clone (required for initialize_go_server_ubuntu.sh)
   * `GIT_BRANCH`: Git branch to use (required for initialize_go_server_ubuntu.sh)
   * `SERVICE_USER`: User to run the service as (required for initialize_go_server_ubuntu.sh)
   * `SERVICE_DESCRIPTION`: Description for the systemd service
   * `SERVICE_WORKING_DIR`: Working directory for the service (defaults to PROJECT_DIR if not set)
   * `PROJECT_DIR`: Absolute path to your Go project's Git repository (e.g., `/srv/myapp/source`).
   * `GO_EXECUTABLE_NAME`: The name of your compiled Go binary (e.g., `myapp-server`).
   * `GO_EXECUTABLE_DEST`: The full path where the live executable is located and should be updated (e.g., `/usr/local/bin/myapp-server`).
   * `RC_SERVICE_NAME`: The name of your systemd service (e.g., `myapp-server`).
   * `LOG_DIR`: Directory where daily log files will be stored (e.g., `/var/log/go_project_updater`).
   * `LOG_BASE_NAME`: The base name for log files (e.g., `myapp_updater`).
   * `BUILD_USER` (Optional): Username to run `git pull` and `go build` as. If empty, these commands run as the user executing the script.

The `config.sh` file is ignored by Git, so your local settings won't be overwritten when you pull updates from the repository.

## Setup Instructions

### 1. Basic Setup

1. **Clone the Repository**: Clone this repository to your desired location.
   ```bash
   git clone https://github.com/yourusername/GoCronBuild.git
   cd GoCronBuild
   ```

2. **Configure the Script**: 
   ```bash
   cp config.example.sh config.sh
   # Edit config.sh with your specific settings
   nano config.sh
   ```

3. **Make the Scripts Executable**:
   ```bash
   chmod +x update_go_server_ubuntu.sh generate_sudo_permissions.sh initialize_go_server_ubuntu.sh create_users_ubuntu.sh
   ```

### 2. User Setup (Optional)

If you want to use dedicated users for building and running your Go application (recommended for security), you can use the `create_users_ubuntu.sh` script to set them up:

```bash
# Edit config.sh first to define BUILD_USER and SERVICE_USER

# Run the user setup script with sudo
sudo ./create_users_ubuntu.sh
```

This script will:

* Create the BUILD_USER (if specified) as a system user
* Create the SERVICE_USER (if specified and different from BUILD_USER) as a system user
* Set up appropriate permissions on project directories
* Create Go cache directories for the build user
* Ensure all necessary directories exist with proper permissions

### 3. Generate Sudo Permissions

Generate the necessary sudo permissions for your users:

```bash
./generate_sudo_permissions.sh
```

This will create a `sudoers.txt` file with the necessary sudo configuration entries based on your `config.sh` settings.

Create a dedicated sudoers file and add the entries:

```bash
# Review the generated entries first
nano sudoers.txt

# Create a dedicated sudoers file (this will open an editor)
sudo visudo -f /etc/sudoers.d/gocronbuild

# After adding the entries and saving, set proper permissions
sudo chmod 440 /etc/sudoers.d/gocronbuild

# Verify the sudoers syntax
sudo visudo -c -f /etc/sudoers.d/gocronbuild
```

> **⚠️ Security Warning**: Always use `visudo` to edit sudoers files to avoid syntax errors that could lock you out of the system. Never use standard text editors directly on sudoers files.

### 4. Initialize the Go Server

The `initialize_go_server_ubuntu.sh` script handles the complete setup process for your Go application:

```bash
./initialize_go_server_ubuntu.sh
```

This script will:

* Clone your Git repository (using BUILD_USER if specified)
* Build the Go application
* Create a systemd service unit
* Start the service
* Enable the service to start on boot
* Generate sudo permissions

The script provides detailed logs of each step and a summary at the end with commands for managing the service.

## Managing the Service

After setting up the service with the initialization script, you can manage it using standard systemd commands:

```bash
# Start the service
sudo systemctl start [service-name]

# Stop the service
sudo systemctl stop [service-name]

# Restart the service
sudo systemctl restart [service-name]

# Check service status
sudo systemctl status [service-name]

# Enable service to start on boot
sudo systemctl enable [service-name]

# Disable service from starting on boot
sudo systemctl disable [service-name]
```

You can view the service logs with:

```bash
# View all logs
sudo journalctl -u [service-name]

# Follow logs in real-time
sudo journalctl -u [service-name] -f
```

### 5. Handling Git Ownership Issues

When working with repositories owned by different users, you might encounter this error:
```
fatal: detected dubious ownership in repository at '/path/to/repo'
```

This is a Git security feature. The script automatically handles this error by:

* Detecting the "dubious ownership" error message
* Extracting the repository path from the error
* Running `git config --global --add safe.directory /path/to/repo` automatically
* Retrying the Git operation that failed

This automatic handling works for all Git operations in the script (rev-parse, pull, etc.).

If you prefer to manually configure this, you can:

* Configure Git to allow the specific directory:
  ```bash
  # As the user running the script
  git config --global --add safe.directory /path/to/your/go/project
  
  # Or as the BUILD_USER (if applicable)
  sudo -u yourbuilduser git config --global --add safe.directory /path/to/your/go/project
  ```

* Or disable the check completely (less secure):
  ```bash
  git config --global safe.directory '*'
  ```

### 6. Public Repository Support

The script includes fallback mechanisms for public repositories, allowing it to work even without sudo permissions:

* If a sudo command fails with `sudo: a password is required`, the script will automatically attempt the operation without sudo
* This works for git pull, go build, file operations, and service management
* This is particularly useful for testing or when working with public repositories where elevated permissions aren't strictly necessary
* For production use with private repositories or system directories, proper sudo permissions are still recommended

### 7. Manual Execution (Testing)

Run the script manually to test its functionality and check the log output:
```bash
# Normal execution - only updates if Git changes are detected
./update_go_server_ubuntu.sh

# Force rebuild and service restart even if no Git changes are detected
./update_go_server_ubuntu.sh --force
```
Check the log file (e.g., `/var/log/go_project_updater/go_project_updater_YYYY-MM-DD.log`) for detailed output.

The `--force` option is useful in scenarios where you need to rebuild and restart the service without code changes, such as after modifying configuration files or when troubleshooting service issues.

## Setting up as a Cron Job

To automate the update process, you can run the update script via cron:

1. Edit the crontab (as the user with appropriate sudo permissions):
   ```bash
   crontab -e
   ```

2. Add a cron job entry:
   ```cron
   # Run daily at 3:00 AM
   0 3 * * * /path/to/GoCronBuild/update_go_server_ubuntu.sh
   ```

   Or to run every hour:
   ```cron
   0 * * * * /path/to/GoCronBuild/update_go_server_ubuntu.sh
   ```

## Troubleshooting

* **Permission Issues**: Ensure that your sudoers configuration includes the appropriate `NOPASSWD` entries for the user running the cron job.
* **Service Fails to Start**: Check the service logs with `sudo journalctl -u [service-name]` for error messages.
* **Git Authentication**: If your Git repository is private and uses SSH authentication, ensure the user has its SSH key correctly set up.

## Logging

* The script creates a new log file each day in the `LOG_DIR` directory, named `LOG_BASE_NAME_YYYY-MM-DD.log`.
* Logs older than 90 days within `LOG_DIR` matching the pattern `LOG_BASE_NAME_*.log` are automatically deleted at the beginning of each script run.
* All significant actions, errors, and outputs from commands are logged.

## Error Handling and Rollback

* The script exits immediately if critical errors occur (e.g., project directory not found, build failure, failure to back up executable).
* If the service restart command fails after a new executable is put in place, the script will:
    1. Attempt to move the backup created during that run back to the live executable path.
    2. Log the success or failure of this rollback.
    3. Attempt to restart the service with the (now restored) old executable.
    4. Exit with an error status. The backup file (which is now the restored executable) is *not* deleted in this failure scenario.
* If the service restarts successfully with the new version, the backup file created *during that specific run* is deleted.

## Security Considerations

* Use dedicated users for building and running the service to follow the principle of least privilege.
* Regularly review and update the sudo permissions to ensure they're as restrictive as possible.
* Consider using SSH keys with passphrases for Git authentication in production environments.