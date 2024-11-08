# Scripts Repository

This repository contains various utility scripts to help with everyday tasks. The focus is on simplicity and usability.

## Script: convert-images-webp.sh

This script converts image files from various formats (jpg, jpeg, png, bmp, gif, tiff) to the WebP format.

### Usage

To use the `convert-images-webp.sh` script, follow these steps:

1. **Install Dependencies**: Ensure that `cwebp` is installed on your system. The script will prompt you to install it if it's not found.

2. **Run the Script**: Execute the script using the following command:

    ```sh
    ./convert-images-webp.sh [input_directory] [output_directory]
    ```
    
    - **input_directory**: The directory containing the images to be converted. If not provided, the current directory will be used.
    - **output_directory**: The directory where the converted images will be saved. This is a required argument.
    
    For example:
    
    ```sh
    ./convert-images-webp.sh ./images ./webp-images
    ```

This command will convert all supported images in the `./images` directory to WebP format and save them in the `./webp-images` directory.

### Script Details

- The script checks if `cwebp` is installed and offers to install it if not.
- It processes all images in the specified input directory and converts them to WebP format, preserving the directory structure.
- The script supports the following image formats: jpg, jpeg, png, bmp, gif, tiff.

### Additional Information

- The script creates the output directory if it does not exist.
- It skips converting images if the WebP version already exists in the output directory.

For more details, check the script [here](https://github.com/FmTod/scripts/blob/master/convert-images-webp.sh).
