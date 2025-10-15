#!/usr/bin/env bash

# MariaDB Backup Import Script
# This script imports SQL backup files into their corresponding MariaDB databases

# Configuration
MYSQL_USER="root"
MYSQL_OPTS="-u${MYSQL_USER}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${BLUE}📋 $1${NC}"; }

# Function to extract database name from file content
extract_db_from_content() {
    local file="$1"
    
    # Look for the database name in the comment section
    local db_line=$(grep -m1 "^-- Host: .* Database: " "$file" 2>/dev/null || true)
    
    if [[ -n "$db_line" ]]; then
        # Extract database name using parameter expansion
        local db_name=$(echo "$db_line" | sed -n 's/^-- Host: .* Database: \(.*\)$/\1/p')
        echo "$db_name"
    fi
}

# Function to extract database name from filename
extract_db_from_filename() {
    local filename="$1"
    local basename=$(basename "$filename" .sql)
    
    # Pattern: mylisterhub_{database_name}_*_backup_*
    # For central: mylisterhub_central_marketplace_categories_backup_2025-10-15.sql
    # For tenants: mylisterhub_tenant116_category_mappings_backup_2025-10-15.sql
    if [[ $basename =~ ^mylisterhub_(central)_.*_backup_.* ]]; then
        echo "mylisterhub_central"
    elif [[ $basename =~ ^mylisterhub_(tenant[0-9]+)_.*_backup_.* ]]; then
        echo "mylisterhub_${BASH_REMATCH[1]}"
    fi
}

# Function to check if database exists
database_exists() {
    local db_name="$1"
    
    local result=$(mysql $MYSQL_OPTS -e "SHOW DATABASES LIKE '$db_name';" 2>/dev/null | wc -l)
    
    # If result is greater than 1 (header + data), database exists
    [[ $result -gt 1 ]]
}

# Function to warn about missing database
warn_missing_database() {
    local db_name="$1"
    
    print_warning "Database '$db_name' does not exist and will not be created automatically"
    print_info "Please create the database manually with:"
    echo "  mysql -u $MYSQL_USER -e \"CREATE DATABASE \\\`$db_name\\\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
}

# Function to import SQL file into database
import_sql_file() {
    local file_path="$1"
    local db_name="$2"
    
    print_info "Importing $(basename "$file_path") into database $db_name..."
    
    if mysql $MYSQL_OPTS "$db_name" < "$file_path" 2>/dev/null; then
        print_success "Successfully imported $(basename "$file_path") into $db_name"
        return 0
    else
        print_error "Failed to import $(basename "$file_path")"
        return 1
    fi
}

# Function to check MySQL access
check_mysql_access() {
    print_info "Testing MySQL connection..."
    
    if ! mysql $MYSQL_OPTS -e "SELECT 1;" >/dev/null 2>&1; then
        print_error "MySQL connection failed. Please ensure:"
        echo "1. MariaDB/MySQL is running"
        echo "2. User '$MYSQL_USER' has appropriate permissions"
        echo "3. You may need to provide a password (use -p flag)"
        echo ""
        echo "Example with password: mysql -u$MYSQL_USER -p"
        exit 1
    fi
    
    print_success "MySQL connection successful"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] <backup_directory>"
    echo ""
    echo "Arguments:"
    echo "  backup_directory    Path to directory containing SQL backup files"
    echo ""
    echo "Options:"
    echo "  -p, --password     Prompt for MySQL password"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/backups"
    echo "  $0 -p /path/to/backups"
    echo "  $0 --password /home/user/sql_backups"
}

# Main execution function
main() {
    local backup_dir="$1"
    
    # Validate backup directory argument
    if [[ -z "$backup_dir" ]]; then
        print_error "Backup directory path is required!"
        echo ""
        show_usage
        exit 1
    fi
    
    # Check if directory exists
    if [[ ! -d "$backup_dir" ]]; then
        print_error "Directory '$backup_dir' does not exist!"
        exit 1
    fi
    
    # Check if directory is readable
    if [[ ! -r "$backup_dir" ]]; then
        print_error "Directory '$backup_dir' is not readable!"
        exit 1
    fi
    
    echo "Starting MariaDB Category Backup Import..."
    echo "=========================================="
    echo
    
    print_info "Backup directory: $backup_dir"
    
    # Find all SQL backup files in the specified directory
    local sql_files=("$backup_dir"/*.sql)
    
    if [[ ${#sql_files[@]} -eq 1 && "${sql_files[0]}" == "$backup_dir/*.sql" ]]; then
        print_error "No SQL files found in directory '$backup_dir'!"
        exit 1
    fi
    
    print_info "Found ${#sql_files[@]} SQL backup files"
    echo
    
    # Counters
    local successful=0
    local failed=0
    local failed_files=()
    local success_files=()
    
    # Process each SQL file
    for file in "${sql_files[@]}"; do
        local filename=$(basename "$file")
        echo "Processing: $filename"
        
        # Try to extract database name from filename first
        local db_name=$(extract_db_from_filename "$filename")
        
        # If filename extraction fails, try content extraction
        if [[ -z "$db_name" ]]; then
            db_name=$(extract_db_from_content "$file")
        fi
        
        if [[ -z "$db_name" ]]; then
            print_error "Could not determine database name for $filename"
            failed_files+=("$filename: Could not determine database name")
            ((failed++))
            echo
            continue
        fi
        
        print_info "Database: $db_name"
        
        # Check if database exists, warn if it doesn't
        if ! database_exists "$db_name"; then
            warn_missing_database "$db_name"
            print_error "Skipping import for $filename due to missing database"
            failed_files+=("$filename: Database '$db_name' does not exist")
            ((failed++))
            echo
            continue
        else
            print_success "Database $db_name exists"
        fi
        
        # Import the SQL file
        if import_sql_file "$file" "$db_name"; then
            success_files+=("$filename → $db_name")
            ((successful++))
        else
            failed_files+=("$filename: Import failed")
            ((failed++))
        fi
        
        echo
    done
    
    # Print summary
    echo "Import Summary:"
    echo "==============="
    print_success "Successful imports: $successful"
    print_error "Failed imports: $failed"
    
    if [[ $failed -gt 0 ]]; then
        echo
        echo "Failed imports:"
        for item in "${failed_files[@]}"; do
            echo "  - $item"
        done
    fi
    
    if [[ $successful -gt 0 ]]; then
        echo
        echo "Successful imports:"
        for item in "${success_files[@]}"; do
            echo "  - $item"
        done
    fi
    
    echo
    if [[ $failed -eq 0 ]]; then
        print_success "All imports completed successfully!"
        exit 0
    else
        print_warning "Some imports failed. Please check the errors above."
        exit 1
    fi
}

# Parse command line arguments
backup_directory=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--password)
            echo "Enter MySQL password:"
            read -s mysql_password
            MYSQL_OPTS="$MYSQL_OPTS -p$mysql_password"
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*|--*)
            print_error "Unknown option $1"
            echo ""
            show_usage
            exit 1
            ;;
        *)
            if [[ -z "$backup_directory" ]]; then
                backup_directory="$1"
            else
                print_error "Multiple directories specified. Only one directory is allowed."
                echo ""
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate that backup directory was provided
if [[ -z "$backup_directory" ]]; then
    print_error "Backup directory path is required!"
    echo ""
    show_usage
    exit 1
fi

# Check MySQL access first
check_mysql_access

# Run main function
main "$backup_directory"