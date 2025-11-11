#!/bin/bash

# Script to update metadata for files in S3 bucket using s4cmd
# Usage: ./s3-webp-metadata.sh <bucket-name> [options]

set -e

# Check if s4cmd is installed
if ! command -v s4cmd &> /dev/null; then
    echo "Error: s4cmd is not installed. Please install it first:"
    echo "  pip install s4cmd"
    exit 1
fi

# Default values
DRY_RUN=false
BUCKET=""
PREFIX=""
EXTENSIONS="webp"
CONTENT_TYPE="image/webp"
REGION="us-mia-1"
ENDPOINT_URL=""
RECURSIVE=false
VERBOSE=false
JOBS=8

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --recursive)
            RECURSIVE=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --jobs|-j)
            JOBS="$2"
            shift 2
            ;;
        --extensions|-e)
            EXTENSIONS="$2"
            shift 2
            ;;
        --content-type|-t)
            CONTENT_TYPE="$2"
            shift 2
            ;;
        --region|-r)
            REGION="$2"
            shift 2
            ;;
        --endpoint-url|-u)
            ENDPOINT_URL="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 <bucket-name> [prefix] [options]"
            echo ""
            echo "Arguments:"
            echo "  bucket-name          S3 bucket name (required)"
            echo "  prefix               S3 prefix/path (optional)"
            echo ""
            echo "Options:"
            echo "  --dry-run            Preview changes without applying them"
            echo "  --recursive          Search for files recursively in subdirectories"
            echo "  -v, --verbose        Show detailed s4cmd output"
            echo "  -j, --jobs           Number of parallel jobs (default: 8, requires GNU parallel)"
            echo "  -e, --extensions     Comma-separated file extensions (default: webp)"
            echo "  -t, --content-type   Content-Type header (default: image/webp)"
            echo "  -r, --region         S3 region (default: us-mia-1)"
            echo "  -u, --endpoint-url   Custom endpoint URL (overrides region)"
            echo ""
            echo "Examples:"
            echo "  $0 my-bucket images/"
            echo "  $0 my-bucket images/ --dry-run"
            echo "  $0 my-bucket images/ --recursive"
            echo "  $0 my-bucket images/ --verbose"
            echo "  $0 my-bucket images/ --jobs 16"
            echo "  $0 my-bucket --extensions webp,jpg,png --content-type image/webp"
            echo "  $0 my-bucket videos/ --extensions webm --content-type video/webm"
            echo "  $0 my-bucket --region us-east-1"
            echo "  $0 my-bucket --endpoint-url https://custom.s3.endpoint.com"
            exit 0
            ;;
        *)
            if [ -z "$BUCKET" ]; then
                BUCKET="$1"
            elif [ -z "$PREFIX" ]; then
                PREFIX="$1"
            fi
            shift
            ;;
    esac
done

# Check if bucket name is provided
if [ -z "$BUCKET" ]; then
    echo "Error: bucket-name is required"
    echo ""
    echo "Usage: $0 <bucket-name> [prefix] [options]"
    echo "Use --help for more information"
    exit 1
fi

# Metadata to set
CACHE_CONTROL="public, max-age=31536000, immutable"

# Set endpoint URL
if [ -z "$ENDPOINT_URL" ]; then
    ENDPOINT_URL="https://${REGION}.linodeobjects.com"
fi

# Build grep pattern for extensions
IFS=',' read -ra EXT_ARRAY <<< "$EXTENSIONS"
GREP_PATTERN=""
for ext in "${EXT_ARRAY[@]}"; do
    ext=$(echo "$ext" | xargs)  # trim whitespace
    if [ -z "$GREP_PATTERN" ]; then
        GREP_PATTERN="\.${ext}$"
    else
        GREP_PATTERN="${GREP_PATTERN}\|\.${ext}$"
    fi
done

# Check if parallel is available
HAS_PARALLEL=false
if command -v parallel &> /dev/null; then
    HAS_PARALLEL=true
fi

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN MODE - No changes will be made"
    echo ""
fi

echo "Processing files in s3://${BUCKET}/${PREFIX}"
echo "Endpoint URL: ${ENDPOINT_URL}"
echo "Mode: $([ "$RECURSIVE" = true ] && echo "Recursive" || echo "Non-recursive")"
if [ "$HAS_PARALLEL" = true ] && [ "$DRY_RUN" = false ]; then
    echo "Parallel processing: Enabled (${JOBS} jobs)"
else
    echo "Parallel processing: Disabled"
fi
echo "Extensions: ${EXTENSIONS}"
echo "Content-Type: ${CONTENT_TYPE}"
echo "Cache-Control: ${CACHE_CONTROL}"
echo ""

# List all matching files in the bucket
echo "Finding files..."

# Build s4cmd ls command with optional recursive flag
LS_CMD="s4cmd ls"
if [ "$RECURSIVE" = true ]; then
    LS_CMD="s4cmd ls -r"
fi

if [ "$VERBOSE" = true ]; then
    echo "Running: $LS_CMD s3://${BUCKET}/${PREFIX} --endpoint-url ${ENDPOINT_URL}"
    echo ""
fi

# Function to update a single file's metadata
update_file() {
    local file="$1"
    local content_type="$2"
    local cache_control="$3"
    local endpoint_url="$4"
    local verbose="$5"
    
    echo "Updating metadata for: ${file}"
    
    if [ "$verbose" = true ]; then
        s4cmd cp \
            --force \
            --API-ACL=public-read \
            --API-MetadataDirective=REPLACE \
            --API-ContentType="${content_type}" \
            --API-CacheControl="${cache_control}" \
            --endpoint-url "${endpoint_url}" \
            "${file}" "${file}"
        EXIT_CODE=$?
    else
        s4cmd cp \
            --force \
            --API-ACL=public-read \
            --API-MetadataDirective=REPLACE \
            --API-ContentType="${content_type}" \
            --API-CacheControl="${cache_control}" \
            --endpoint-url "${endpoint_url}" \
            "${file}" "${file}" 2>&1 | grep -v "^copy:" | grep -v "^$" || true
        EXIT_CODE=${PIPESTATUS[0]}
    fi
    
    if [ $EXIT_CODE -eq 0 ]; then
        echo "  ✓ Successfully updated: ${file}"
    else
        echo "  ✗ Failed to update: ${file}"
        return 1
    fi
}

# Export function and variables for parallel
export -f update_file
export CONTENT_TYPE
export CACHE_CONTROL
export ENDPOINT_URL
export VERBOSE

# Get list of files
FILE_LIST=$($LS_CMD "s3://${BUCKET}/${PREFIX}" --endpoint-url "${ENDPOINT_URL}" 2>&1 | \
    tee >([ "$VERBOSE" = true ] && cat >&2 || cat > /dev/null) | \
    grep -iE "${GREP_PATTERN}" | \
    awk '{print $NF}')

# Count files
FILE_COUNT=$(echo "$FILE_LIST" | grep -c '^' || echo "0")

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "No matching files found."
    exit 0
fi

echo "Found ${FILE_COUNT} file(s) to process"
echo ""

if [ "$DRY_RUN" = true ]; then
    # Dry run: just list files
    echo "$FILE_LIST" | while read -r file; do
        echo "Would update metadata for: ${file}"
    done
else
    # Process files
    if [ "$HAS_PARALLEL" = true ] && [ "$FILE_COUNT" -gt 1 ]; then
        # Use GNU parallel for concurrent processing
        echo "Processing files in parallel with ${JOBS} jobs..."
        echo ""
        
        # Use environment variables instead of passing as arguments to avoid quoting issues
        echo "$FILE_LIST" | parallel -j "$JOBS" --line-buffer --tagstring "[{}]" \
            update_file {} \"\$CONTENT_TYPE\" \"\$CACHE_CONTROL\" \"\$ENDPOINT_URL\" \"\$VERBOSE\"
        
        PARALLEL_EXIT=$?
        if [ $PARALLEL_EXIT -ne 0 ]; then
            echo ""
            echo "Warning: Some files failed to update (exit code: $PARALLEL_EXIT)"
        fi
    else
        # Sequential processing (no parallel or single file)
        if [ "$FILE_COUNT" -eq 1 ]; then
            echo "Processing single file..."
        else
            echo "Processing files sequentially..."
            if [ "$HAS_PARALLEL" = false ]; then
                echo "(Install GNU parallel with: apt-get install parallel OR brew install parallel)"
            fi
        fi
        echo ""
        
        echo "$FILE_LIST" | while read -r file; do
            update_file "$file" "$CONTENT_TYPE" "$CACHE_CONTROL" "$ENDPOINT_URL" "$VERBOSE"
        done
    fi
fi

echo ""
if [ "$DRY_RUN" = true ]; then
    echo "Dry run complete! Use without --dry-run to apply changes."
else
    echo "Metadata update complete!"
fi
