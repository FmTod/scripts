#!/bin/bash

# Function to check if ffmpeg is installed and prompt installation if not
install_ffmpeg_if_needed() {
  if ! command -v ffmpeg &> /dev/null; then
    echo "ffmpeg is not installed. Would you like to install it? (y/n)"
    read -r install_choice
    if [[ "$install_choice" == "y" || "$install_choice" == "Y" ]]; then
      sudo apt update && sudo apt install -y ffmpeg
      if ! command -v ffmpeg &> /dev/null; then
        echo "Installation failed. Please install ffmpeg manually and rerun the script."
        exit 1
      fi
    else
      echo "ffmpeg is required to run this script. Exiting."
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

# List of video file extensions to include
extensions="mp4 avi mov mkv wmv flv webm"

# Function to convert videos to .mp4 (or another chosen format) and preserve directory structure
convert_videos() {
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
    output_file="$dst_dir/${relative_path%.*}.mp4" # Change .mp4 to your desired output format if necessary.
    output_dir_path="$(dirname "$output_file")"

    # Check if the output file already exists
    if [[ -f "$output_file" ]]; then
      echo "Skipping '$file' as the converted file already exists."
      continue
    fi

    # Create target directory if it doesn't exist
    mkdir -p "$output_dir_path"

    # Convert the file to .mp4 using ffmpeg
    # This is a basic conversion command. You may need to adjust the options 
    # based on your desired quality, bitrate, codec, etc.
    ffmpeg -i "$file" -c:v libx264 -preset medium -crf 23 -c:a aac -b:a 128k "$output_file"
    
    if [[ $? -eq 0 ]]; then
        echo "Converted '$file' to '$output_file'"
    else
        echo "Error converting '$file' to '$output_file'"
    fi
  done
}

# Check and install ffmpeg if necessary
install_ffmpeg_if_needed

# Run the conversion function
convert_videos "$input_dir" "$output_dir"

echo "All videos converted successfully."
