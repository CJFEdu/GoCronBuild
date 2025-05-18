# Go Cron Build

This shell script automates the process of updating a Go application deployed on Alpine Linux using OpenRC and `doas`. It is designed to be run as a cron job to periodically check for updates in a Git repository, rebuild the Go application if changes are found, and then restart the corresponding `rc-service`.

## Features

* **Git Integration**: Pulls the latest changes from a specified Git repository.
* **Conditional Rebuild**: Only rebuilds the Go application if new commits are pulled.
* **Safe Updates**:
    * Builds the new executable to a temporary file.
    * If the build is successful, it backs up the current live executable.
    * Moves the newly built executable into the live location.
* **Service Restart**: Restarts the specified `rc-service` after a successful update.
* **Rollback on Restart Failure**: If the service fails to restart with the new executable, it attempts to move the backup executable back into place and restart the service again.
* **Logging**:
    * Maintains daily log files (e.g., `go_project_updater_YYYY-MM-DD.log`).
    * Automatically cleans up log files older than 90 days.
* **Backup Management**:
    * Creates a timestamped backup of the live executable before replacing it (e.g., `yourgoserver.bak_YYYYMMDDHHMMSS`).
    * Deletes the backup created during the current run if the service restarts successfully with the new version. Older backups are not automatically deleted by this specific mechanism but could be managed by a separate cleanup policy if needed.
* **Alpine Linux Focused**: Uses `doas` for privilege escalation and `rc-service` for service management.

## Prerequisites

Before using this script, ensure the following are installed and configured on your Alpine Linux system:

1.  **Git**: (`/usr/bin/git` or as configured in the script)
2.  **Go**: (`/usr/local/go/bin/go` or as configured in the script)
3.  **doas**: (`/usr/bin/doas` or as configured in the script)
    * The user running the cron job (or the `BUILD_USER` if specified) must have `doas` permissions configured in `/etc/doas.conf`.
    * The script uses the `-n` flag with all doas commands to prevent password prompts. This ensures the script can run unattended, but requires that the `nopass` option is correctly configured in `/etc/doas.conf`.
    * We provide a helper script to generate the necessary doas configuration:
        ```bash
        ./generate_doas_permissions.sh
        ```
      This will create a `doas.txt` file with the appropriate entries for your configuration, which you can then add to your `/etc/doas.conf` file.
    * The generated permissions will include entries for:
        * Running `git pull` and `go build` as `BUILD_USER` (if `BUILD_USER` is set)
        * Moving executables in system directories (e.g., `/usr/local/bin/`)
        * Deleting backup executables
        * Restarting services with `rc-service`
    * The script generates both `nopass` entries (for automated execution) and regular entries (for manual execution with password prompts)
4.  **An existing Go project managed with Git.**
5.  **An OpenRC init script** for your Go application, managed by `rc-service`.

## Configuration

The script uses an external configuration file (`config.sh`) to store all environment-specific settings. A template file (`config.example.sh`) is provided that you should copy and customize:

1. Copy the example configuration file to create your own configuration:
   ```bash
   cp config.example.sh config.sh
   ```

2. Edit `config.sh` and modify these variables to match your environment:
   * `PROJECT_DIR`: Absolute path to your Go project's Git repository (e.g., `/srv/myapp/source`).
   * `GO_EXECUTABLE_NAME`: The name of your compiled Go binary (e.g., `myapp-server`).
   * `GO_EXECUTABLE_DEST`: The full path where the live executable is located and should be updated (e.g., `/usr/local/bin/myapp-server`). This path must match the `command` in your OpenRC init script.
   * `RC_SERVICE_NAME`: The name of your `rc-service` (e.g., `myapp-server`).
   * `LOG_DIR`: Directory where daily log files will be stored (e.g., `/var/log/go_project_updater`). The script will attempt to create this directory.
   * `LOG_BASE_NAME`: The base name for log files (e.g., `myapp_updater`).
   * `BUILD_USER` (Optional): Username to run `git pull` and `go build` as. If empty, these commands run as the user executing the script (e.g., the cron user). See the [Setting Up BUILD_USER](#setting-up-build_user) section for instructions on creating and configuring this user.
   * `GIT_CMD`, `GO_CMD`, `RC_SERVICE_CMD`, `DOAS_CMD`: Verify these absolute paths to the respective commands.

The `config.sh` file is ignored by Git, so your local settings won't be overwritten when you pull updates from the repository.

## Usage

1.  **Clone the Repository**: Clone this repository to your desired location.
2.  **Configure the Script**: 
    ```bash
    cp config.example.sh config.sh
    # Edit config.sh with your specific settings
    nano config.sh
    ```
3.  **Make the Scripts Executable**:
    ```bash
    chmod +x update_go_server.sh generate_doas_permissions.sh
    ```
4.  **Generate doas Permissions**:
    ```bash
    ./generate_doas_permissions.sh
    ```
    This will create a `doas.txt` file with the necessary doas configuration entries based on your `config.sh` settings.
    Add these entries to your `/etc/doas.conf` file:
    ```bash
    # Review the generated entries first
    cat doas.txt
    
    # Then add them to your doas.conf (requires root privileges)
    doas sh -c "cat doas.txt >> /etc/doas.conf"
    
    # Verify the doas.conf syntax
    doas -C /etc/doas.conf
    ```
5.  **Handling Git Ownership Issues**:
    When working with repositories owned by different users, you might encounter this error:
    ```
    fatal: detected dubious ownership in repository at '/path/to/repo'
    ```
    
    This is a Git security feature. To resolve it, you can either:
    
    * Configure Git to allow the specific directory:
      ```bash
      # As the user running the script
      git config --global --add safe.directory /path/to/your/go/project
      
      # Or as the BUILD_USER (if applicable)
      doas -u yourbuilduser git config --global --add safe.directory /path/to/your/go/project
      ```
    
    * Or disable the check completely (less secure):
      ```bash
      git config --global safe.directory '*'
      ```

6.  **Manual Execution (Testing)**:
    Run the script manually to test its functionality and check the log output:
    ```bash
    ./update_go_server.sh
    ```
    Check the log file (e.g., `/var/log/go_project_updater/go_project_updater_YYYY-MM-DD.log`) for detailed output.

## Setting Up BUILD_USER

If you want to use a dedicated user for building your Go application (recommended for security), follow these steps to create and configure the `BUILD_USER`:

1. **Create the user**:
   ```bash
   # Create a new user without a home directory
   doas adduser -D -H yourbuilduser
   
   # Or create a user with a home directory if needed
   doas adduser -D yourbuilduser
   ```

2. **Set up the project directory with proper permissions**:
   ```bash
   # Switch to the build user
   doas -u yourbuilduser sh
   
   # Create or clone the project directory
   mkdir -p /path/to/project/parent
   cd /path/to/project/parent
   
   # Clone your repository (if using Git)
   git clone https://github.com/yourusername/yourrepo.git
   
   # Exit the build user shell
   exit
   ```

3. **Set proper ownership and permissions**:
   ```bash
   # If the directory already exists and you need to change ownership
   doas chown -R yourbuilduser:yourbuilduser /path/to/your/go/project
   
   # Make sure the directory is accessible to the cron user as well
   doas chmod -R 750 /path/to/your/go/project
   ```

4. **Update your `config.sh`**:
   ```bash
   # Edit config.sh and set BUILD_USER to your new user
   BUILD_USER="yourbuilduser"
   ```

5. **Generate doas permissions**:
   ```bash
   # Run the permissions generator to create entries for the BUILD_USER
   ./generate_doas_permissions.sh
   ```

6. **Test the setup**:
   ```bash
   # Try running the update script to ensure permissions are correct
   ./update_go_server.sh
   ```

Using a dedicated build user provides better security by isolating the build process from both the root user and the cron user. This follows the principle of least privilege, where each component has only the permissions it needs to function.

## Setting up as a Cron Job

To automate the update process, you can run this script via cron.

1.  **Edit the crontab**:
    It's generally recommended to run this script from a user that has the necessary `doas` permissions configured (often root, or a dedicated service/cron user).
    To edit root's crontab:
    ```bash
    doas crontab -e
    ```
    Or for a specific user:
    ```bash
    crontab -e
    ```

2.  **Add a Cron Job Entry**:
    The format is `MINUTE HOUR DAY_OF_MONTH MONTH DAY_OF_WEEK COMMAND`.

    * To run the script daily at 3:00 AM:
        ```cron
        0 3 * * * /path/to/GoCronBuild/update_go_server.sh
        ```
    * To run every hour:
        ```cron
        0 * * * * /path/to/GoCronBuild/update_go_server.sh
        ```

    **Important Considerations for Cron:**
    * **Environment:** Cron jobs run with a minimal environment. The script uses absolute paths for commands to mitigate `PATH` issues. If your Go build process depends on specific environment variables (e.g., `GOPATH`, `GOCACHE`, `GOMODCACHE`), ensure they are either set within the script itself or defined in the crontab entry.
        ```cron
        0 3 * * * GOPATH=/home/user/go GOCACHE=/home/user/.cache/go-build /path/to/GoCronBuild/update_go_server.sh
        ```
    * **`doas` Configuration**: Ensure your `/etc/doas.conf` allows the user running the cron job to execute the necessary commands without a password prompt if unattended operation is desired.
    * **SSH Keys for Git**: If your Git repository is private and uses SSH authentication, the user under which `git pull` runs (the cron user or `BUILD_USER`) must have its SSH key correctly set up and authorized for the repository, typically without a passphrase for unattended cron jobs.

## Logging

* The script creates a new log file each day in the `LOG_DIR` directory, named `LOG_BASE_NAME_YYYY-MM-DD.log`.
* Logs older than 90 days within `LOG_DIR` matching the pattern `LOG_BASE_NAME_*.log` are automatically deleted at the beginning of each script run.
* All significant actions, errors, and outputs from commands are logged.

## Error Handling and Rollback

* The script exits immediately if critical errors occur (e.g., project directory not found, build failure, failure to back up executable).
* If the `rc-service restart` command fails after a new executable is put in place, the script will:
    1.  Attempt to move the backup created during that run back to the live executable path.
    2.  Log the success or failure of this rollback.
    3.  Attempt to restart the service with the (now restored) old executable.
    4.  Exit with an error status. The backup file (which is now the restored executable) is *not* deleted in this failure scenario.
* If the service restarts successfully with the new version, the backup file created *during that specific run* is deleted.

## Script Variables Overview

(This section would reiterate the configuration variables for quick reference, similar to the "Configuration" section above.)

---

Remember to thoroughly test the script in your environment before relying on it for production updates.
