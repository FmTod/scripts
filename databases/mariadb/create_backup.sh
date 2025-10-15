#!/usr/bin/env bash

# ==============================================================================
# MySQL/MariaDB Table Backup Script with Progress Bar
#
# Description:
#   Backs up a specific table from all databases that match a given prefix,
#   displaying a progress bar for each dump.
#
# Dependencies:
#   - pv (Pipe Viewer): Must be installed for the progress bar.
#     On Debian/Ubuntu: sudo apt-get install pv
#     On CentOS/RHEL:   sudo yum install pv
#     On macOS (Homebrew): brew install pv
#
# Usage:
#   ./backup_mysql_table.sh <user> <host> <db_prefix> <backup_dir> <table_name> [password]
#
# Arguments:
#   user        - The MySQL/MariaDB username.
#   host        - The database host. To use a local socket connection,
#                 provide an empty string: ""
#   db_prefix   - The prefix for the databases to search (e.g., "webapp_").
#   backup_dir  - The full path to the directory to store backups.
#   table_name  - The name of the table to back up (e.g., "orders").
#   password    - (Optional) The user's password. If not provided, the script
#                 will attempt to connect without a password.
# ==============================================================================

# --- Dependency Check ---
if ! command -v pv &> /dev/null
then
    echo "Error: 'pv' (Pipe Viewer) is not installed. It is required for the progress bar."
    echo "Please install it to continue (e.g., 'sudo apt-get install pv')."
    exit 1
fi

# --- Argument Validation ---
if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
    echo "Usage: $0 <user> <host> <db_prefix> <backup_dir> <table_name> [password]"
    exit 1
fi

# --- Configuration from Parameters ---
DB_USER="$1"
DB_HOST="$2"
DATABASE_PREFIX="$3"
BACKUP_DIR="$4"
TABLE_NAME="$5"
DB_PASSWORD="$6" # This will be empty if not provided
DATE=$(date +%F)

# --- Prepare MySQL command arguments ---
# Start with the user.
MYSQL_OPTS="-u${DB_USER}"

# Add the host flag ONLY if the DB_HOST variable is not empty.
# If it's empty, the mysql client will default to a local socket connection.
if [ -n "$DB_HOST" ]; then
    MYSQL_OPTS="${MYSQL_OPTS} -h${DB_HOST}"
fi

# Add the password flag ONLY if the DB_PASSWORD variable is not empty.
if [ -n "$DB_PASSWORD" ]; then
    MYSQL_OPTS="${MYSQL_OPTS} -p${DB_PASSWORD}"
fi


# --- Main Script ---
echo "Starting backup process for table: '$TABLE_NAME'"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Error: Could not create backup directory '$BACKUP_DIR'."
    exit 1
fi

# Get a list of databases matching the prefix.
echo "Fetching list of databases..."
# Note: The arguments are intentionally not quoted to allow shell expansion.
DATABASES=$(mysql $MYSQL_OPTS -e "SHOW DATABASES LIKE '${DATABASE_PREFIX}%';" 2>/dev/null | grep -v Database)

if [ $? -ne 0 ]; then
    echo "Error: Failed to connect to MySQL or execute query. Check your credentials and host."
    exit 1
fi

if [ -z "$DATABASES" ]; then
    echo "No databases found with the prefix '$DATABASE_PREFIX'."
    exit 0
fi

echo "Found databases: $DATABASES"

# Loop through each database found
for db in $DATABASES; do
  # Check if the specified table exists in the current database
  TABLE_EXISTS=$(mysql $MYSQL_OPTS -sN -e "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema = '$db' AND table_name = '$TABLE_NAME');" 2>/dev/null)

  if [ "$TABLE_EXISTS" -eq 1 ]; then
    echo "--> Backing up '$TABLE_NAME' table from database '$db'..."
    BACKUP_FILE="$BACKUP_DIR/${db}_${TABLE_NAME}_backup_${DATE}.sql"
    
    # Get the approximate size of the table for the progress bar
    TABLE_SIZE=$(mysql $MYSQL_OPTS -sN -e "SELECT data_length + index_length FROM information_schema.tables WHERE table_schema = '$db' AND table_name = '$TABLE_NAME';" 2>/dev/null)
    
    # Dump the table, piping through 'pv' to show progress, then to the file.
    # mysqldump warnings are sent to /dev/null to keep the progress bar clean.
    # The 'pv' options show a progress bar, timer, ETA, rate, and byte count.
    mysqldump $MYSQL_OPTS "$db" "$TABLE_NAME" 2>/dev/null | pv -p -t -e -r -b -s $TABLE_SIZE > "$BACKUP_FILE"
    
    # Check the exit status of the pipe. The status of pv is what we care about here.
    if [ ${PIPESTATUS[1]} -eq 0 ]; then
        echo "    Success: Backup saved to $BACKUP_FILE"
    else
        echo "    Error: Failed to back up '$TABLE_NAME' from '$db'."
        # Clean up failed backup file
        rm -f "$BACKUP_FILE"
    fi
  else
    echo "--> Skipping database '$db' (does not contain a '$TABLE_NAME' table)."
  fi
done

echo "Backup process completed."