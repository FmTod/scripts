# Scripts Repository

This repository contains various utility scripts to help with everyday tasks. The focus is on simplicity and usability.

You can run the scripts directly from the repo like so:

```sh
bash <(curl -fsSL https://fmtod.com/scripts?f=<file>) <arguments...>
```

## Script: convert-images-webp.sh

This script converts image files from various formats (jpg, jpeg, png, bmp, gif, tiff) to the WebP format.

<details>
<summary>Details</summary>

### Usage

To use the `convert-images-webp.sh` script, follow these steps:

1. **Install Dependencies**: Ensure that `cwebp` is installed on your system. The script will prompt you to install it if it's not found.

2. **Run the Script**: Execute the script using the following command:

    ```sh
    ./convert-images-webp.sh [input_directory] [output_directory]
    ```
    or you can run it directly:
    ```sh
    bash <(curl -fsSL https://fmtod.com/scripts?f=convert-images-webp.sh) [input_directory] [output_directory]
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
</details>

## Script: convert-videos-webm.sh

This script converts video files from various formats to the WebM format.

<details>
<summary>Details</summary>

### Usage

To use the `convert-videos-webm.sh` script, follow these steps:

1. **Install Dependencies**: Ensure that `ffmpeg` is installed on your system. The script will prompt you to install it if it's not found.

2. **Run the Script**: Execute the script using the following command:

    ```sh
    ./convert-videos-webm.sh [input_directory] [output_directory]
    ```
   or you can run it directly:
    ```sh
    bash <(curl -fsSL https://fmtod.com/scripts?f=convert-videos-webm.sh) [input_directory] [output_directory]
    ```

    - **input_directory**: The directory containing the videos to be converted. If not provided, the current directory will be used.
    - **output_directory**: The directory where the converted videos will be saved. This is a required argument.

   For example:

    ```sh
    ./convert-videos-webm.sh ./videos ./webm-videos
    ```

This command will convert all supported videos in the `./videos` directory to WebM format and save them in the `./webm-videos` directory.

### Script Details

- The script checks if `ffmpeg` is installed and offers to install it if not.
- It processes all videos in the specified input directory and converts them to WebM format, preserving the directory structure.
- The script supports the following video formats: mp4, etc.

### Additional Information

- The script creates the output directory if it does not exist.
- It skips converting videos if the WebM version already exists in the output directory.

For more details, check the script [here](https://github.com/FmTod/scripts/blob/master/convert-videos-webm.sh).
</details>

## Script: pg-dump.sh

This script is designed to dump all data from a PostgreSQL server into an SQL file and optionally compress it using `tar` and `pigz`.

<details>
<summary>Details</summary>

### Usage

To use the `pg_dump_compress.sh` script, follow these steps:

1. **Install Dependencies**: Ensure that `pigz` and `pv` are installed on your system. Compression requires these tools, but the dump itself does not.

2. **Run the Script**: Execute the script using the following command:

    ```sh
    ./pg_dump_compress.sh [OPTIONS]
    ```
    or you can run it directly:
    ```sh
    bash <(curl -fsSL https://fmtod.com/scripts?f=pg_dump_compress.sh) [OPTIONS]
    ```

    Options:
    - `-u, --user USER`  
      Specify the PostgreSQL user \(default: `postgres`\).
    - `-o, --output FILE`  
      Specify the SQL dump file \(default: `postgres.sql`\).
    - `-a, --archive FILE`  
      Specify the compressed archive file \(default: `postgres.tar.gz`\).
    - `-c, --compress`  
      Enable compression using `pigz`.
    - `-l, --level LEVEL`  
      Set the pigz compression level \(e.g., `fast`, `best`; default: `best`\).
    - `-h, --help`  
      Display the help message.

3. **Examples**:

   - Default behavior \(no compression\):
     ```sh
     ./pg_dump_compress.sh
     ```

   - Dump data using a specific PostgreSQL user and enable compression:
     ```sh
     ./pg_dump_compress.sh -u myuser -c
     ```

   - Specify custom filenames for the SQL dump and archive:
     ```sh
     ./pg_dump_compress.sh -o custom.sql -a custom.tar.gz -c -l fast
     ```

### Script Details

- **Dump Process**: Uses `pg_dumpall` to create a full database dump from the specified PostgreSQL user.
- **Compression**: If enabled, the script compresses the SQL dump using `tar` and `pigz`, then deletes the uncompressed file.
- **Defaults**:
  - PostgreSQL user: `postgres`
  - SQL dump file: `postgres.sql`
  - Compressed archive: `postgres.tar.gz`
  - Compression level: `best`

### Additional Information

- The script ensures required commands \(e.g., `pigz`, `pv`\) are installed before compression.
- The uncompressed SQL dump file is removed after compression to save space.
- Compression is optional; if not enabled, the uncompressed SQL file will be preserved.

For more details, check the script [here](https://github.com/FmTod/scripts/blob/master/pg_dump_compress.sh).

</details>

## Database Column Optimization

These Python scripts analyze database columns and generate SQL statements to optimize column data types based on actual content.

<details>
<summary>Details</summary>

### Overview

The Database Column Optimization toolkit includes two main Python scripts:

1. **analyze-columns.py**: Analyzes a MySQL/MariaDB database schema to identify oversized column types based on actual data content.
2. **build-sql.py**: Generates SQL ALTER TABLE statements to implement the recommended optimizations.

### Usage

To use these scripts, follow these steps:

1. **Setup Configuration**: Create a `config.json` file with your database connection details:
   ```json
   {
     "host": "localhost",
     "user": "username",
     "password": "password",
     "central_db": "main_database",
     "tenant_db_pattern": "tenant_%",
     "max_workers": 5,
     "log_level": "INFO",
     "output_file": "schema_optimization_report.csv"
   }
   ```

2. **Run Analysis**:
   ```sh
   python analyze-columns.py
   ```
   This generates a CSV report with optimization recommendations.

3. **Generate SQL**:
   ```sh
   python build-sql.py
   ```
   This creates an SQL file with ALTER TABLE statements based on the analysis.

### Key Features

- Identifies oversized VARCHAR, INT, TEXT, and other column types
- Analyzes multiple databases in parallel
- Generates detailed reports of optimization opportunities
- Creates ready-to-use SQL statements for implementation
- Supports both single-database and multi-tenant environments

### Important Notes

- Always review generated SQL statements before execution
- Test changes in a non-production environment first
- Take database backups before applying schema changes

For more detailed information, see the [full documentation](https://github.com/FmTod/scripts/tree/master/optimze-database-columns).

</details>
`