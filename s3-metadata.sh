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

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN MODE - No changes will be made"
    echo ""
fi

echo "Processing files in s3://${BUCKET}/${PREFIX}"
echo "Endpoint URL: ${ENDPOINT_URL}"
echo "Mode: $([ "$RECURSIVE" = true ] && echo "Recursive" || echo "Non-recursive")"
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

$LS_CMD "s3://${BUCKET}/${PREFIX}" --endpoint-url "${ENDPOINT_URL}" 2>&1 | tee >([ "$VERBOSE" = true ] && cat >&2 || cat > /dev/null) | grep -iE "${GREP_PATTERN}" | awk '{print $NF}' | while read -r file; do
    if [ "$DRY_RUN" = true ]; then
        echo "Would update metadata for: ${file}"
    else
        echo "Updating metadata for: ${file}"
        
        # Copy file to itself with new metadata (this updates the metadata)
        if [ "$VERBOSE" = true ]; then
            s4cmd cp \
                --API-ACL=public-read \
                --API-ContentType="${CONTENT_TYPE}" \
                --API-CacheControl="${CACHE_CONTROL}" \
                --endpoint-url "${ENDPOINT_URL}" \
                "${file}" "${file}"
            EXIT_CODE=$?
        else
            s4cmd cp \
                --API-ACL=public-read \
                --API-ContentType="${CONTENT_TYPE}" \
                --API-CacheControl="${CACHE_CONTROL}" \
                --endpoint-url "${ENDPOINT_URL}" \
                "${file}" "${file}" 2>&1 | grep -v "^copy:" | grep -v "^$" || true
            EXIT_CODE=${PIPESTATUS[0]}
        fi
        
        if [ $EXIT_CODE -eq 0 ]; then
            echo "  ✓ Successfully updated"
        else
            echo "  ✗ Failed to update"
        fi
    fi
done

echo ""
if [ "$DRY_RUN" = true ]; then
    echo "Dry run complete! Use without --dry-run to apply changes."
else
    echo "Metadata update complete!"
fi
