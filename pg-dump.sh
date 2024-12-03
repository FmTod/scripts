#!/bin/bash

# Default values
USER="postgres"
OUTPUT_FILE="postgres.sql"
ARCHIVE_FILE="postgres.tar.gz"
COMPRESS=false
PIGZ_LEVEL="best"

# Function to display help
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Options:"
  echo "  -u, --user USER             Specify the PostgreSQL user (default: postgres)"
  echo "  -o, --output FILE           Specify the output SQL dump file (default: postgres.sql)"
  echo "  -a, --archive FILE          Specify the output archive file (default: postgres.tar.gz)"
  echo "  -c, --compress              Enable compression with pigz"
  echo "  -l, --level LEVEL           Set pigz compression level (e.g., fast, best; default: best)"
  echo "  -h, --help                  Show this help message"
  exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)
      USER="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -a|--archive)
      ARCHIVE_FILE="$2"
      shift 2
      ;;
    -c|--compress)
      COMPRESS=true
      shift 1
      ;;
    -l|--level)
      PIGZ_LEVEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Check for required commands
if ! command -v pigz &> /dev/null && [[ "$COMPRESS" == true ]]; then
  echo "Error: pigz must be installed for compression."
  exit 1
fi
if ! command -v pv &> /dev/null && [[ "$COMPRESS" == true ]]; then
  echo "Error: pv must be installed for compression."
  exit 1
fi

# Dump PostgreSQL data
echo "Dumping PostgreSQL data to $OUTPUT_FILE using user $USER..."
sudo -u "$USER" pg_dumpall > "$OUTPUT_FILE"
if [[ $? -ne 0 ]]; then
  echo "Error: Failed to dump PostgreSQL data."
  exit 1
fi

# Compress the dump if enabled
if [[ "$COMPRESS" == true ]]; then
  echo "Compressing $OUTPUT_FILE into $ARCHIVE_FILE..."
  tar --use-compress-program="pigz --$PIGZ_LEVEL | pv" -cf "$ARCHIVE_FILE" "$OUTPUT_FILE"
  if [[ $? -ne 0 ]]; then
    echo "Error: Compression failed."
    exit 1
  fi
  echo "Deleting uncompressed file $OUTPUT_FILE..."
  rm -f "$OUTPUT_FILE"
else
  echo "Skipping compression. Output file: $OUTPUT_FILE"
fi

echo "Backup complete: ${ARCHIVE_FILE:-$OUTPUT_FILE}"
