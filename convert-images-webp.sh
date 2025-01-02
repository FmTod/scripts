#!/bin/bash

# Function to check if cwebp is installed and prompt installation if not
install_cwebp_if_needed() {
  if ! command -v cwebp &> /dev/null; then
    echo "cwebp is not installed. Would you like to install it? (y/n)"
    read -r install_choice
    if [[ "$install_choice" == "y" || "$install_choice" == "Y" ]]; then
      sudo apt update && sudo apt install -y webp
      if ! command -v cwebp &> /dev/null; then
        echo "Installation failed. Please install cwebp manually and rerun the script."
        exit 1
      fi
    else
      echo "cwebp is required to run this script. Exiting."
      exit 1
    fi
  fi
}

# Set input and output directories based on arguments
if [[ -z "$1" ]]; then
  echo "Usage: $0 [input_directory] [output_directory]"
  echo "Provide at least one argument for the output directory."
  exit 1
fi

if [[ -n "$2" ]]; then
  input_dir="$1"
  output_dir="$2"
else
  input_dir="$PWD"
  output_dir="$1"
fi

# Create the output directory if it doesn't exist
mkdir -p "$output_dir"

# List of image file extensions to include
extensions="jpg jpeg png bmp gif tiff webp"

# Function to convert images to .webp and preserve directory structure
convert_images() {
  local src_dir="$1"
  local dst_dir="$2"

  # Construct the find command for specific extensions
  find_command="find \"$src_dir\" -type f \( $(printf -- "-iname '*.%s' -o " $extensions | sed 's/ -o $//') \)"
  
  # Output the constructed find command for debugging
  echo "Finding files using the following command: $find_command"

  # Execute the constructed find command
  eval "$find_command" | while read -r file; do
    # Calculate the relative path and output file path
    relative_path="${file#$src_dir/}"
    output_file="$dst_dir/${relative_path%.*}.webp"
    output_dir_path="$(dirname "$output_file")"

    # Check if the output file already exists
    if [[ -f "$output_file" ]]; then
      echo "Skipping '$file' as the converted file already exists."
      continue
    fi

    # Create target directory if it doesn't exist
    mkdir -p "$output_dir_path"

    # if file is already in webp we just copy it
    if [[ "$file" == *.webp ]]; then
      echo "File '$file' already in webp format, copying it to '$output_file'"
      cp "$file" "$output_file"
      continue
    fi

    # Convert the file to .webp
    cwebp -q 80 "$file" -o "$output_file"
    echo "Converted '$file' to '$output_file'"
  done
}

# Check and install cwebp if necessary
install_cwebp_if_needed

# Run the conversion function
convert_images "$input_dir" "$output_dir"

echo "All images converted successfully."
