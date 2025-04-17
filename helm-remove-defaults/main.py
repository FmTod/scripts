import argparse
import subprocess
import sys
import io  # Needed for capturing ruamel.yaml output as string if needed

# Use ruamel.yaml instead of pyyaml
from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq

# --- Configuration ---
HELM_EXECUTABLE = "helm"

# --- Helper Functions ---


def run_helm_command(args_list):
    """Runs a Helm command and returns its stdout."""
    command = [HELM_EXECUTABLE] + args_list
    try:
        print(f"Running command: {' '.join(command)}", file=sys.stderr)
        result = subprocess.run(
            command, capture_output=True, text=True, check=True, encoding="utf-8"
        )
        print("Command successful.", file=sys.stderr)
        return result.stdout
    except FileNotFoundError:
        print(f"Error: '{HELM_EXECUTABLE}' command not found.", file=sys.stderr)
        print("Please ensure Helm is installed and in your PATH.", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        print(f"Error running Helm command:", file=sys.stderr)
        print(f"Command: {' '.join(e.cmd)}", file=sys.stderr)
        print(f"Return Code: {e.returncode}", file=sys.stderr)
        print(f"Stderr: {e.stderr}", file=sys.stderr)
        # print(f"Stdout: {e.stdout}", file=sys.stderr) # Often too verbose
        sys.exit(1)
    except Exception as e:
        print(f"An unexpected error occurred: {e}", file=sys.stderr)
        sys.exit(1)


def load_yaml_data(yaml_string_or_stream, filepath="<string>"):
    """Loads YAML data using ruamel.yaml, preserving order."""
    yaml = YAML()
    yaml.preserve_quotes = True  # Optional: Preserve quotes if needed
    try:
        # Load ensures CommentedMap/CommentedSeq are used
        data = yaml.load(yaml_string_or_stream)
        # Handle cases where the YAML content is empty or just comments
        if data is None:
            return CommentedMap()  # Return an empty ordered map
        # If top level is a list, wrap it for consistency? Usually values are dicts.
        # Ensure the top level is a map for easier processing later
        if not isinstance(data, (CommentedMap, dict)):
            print(
                f"Warning: Top level of YAML in {filepath} is not a dictionary/map. Trying to process anyway.",
                file=sys.stderr,
            )
            # Depending on needs, might return data directly or wrap it
            # Returning as is, comparison logic needs to handle non-maps at top level
            return data  # Or potentially return CommentedMap({'_root': data}) ?
        return data

    except Exception as e:  # Catch broader ruamel.yaml errors
        print(f"Error parsing YAML {filepath}: {e}", file=sys.stderr)
        sys.exit(1)


def compare_and_extract_diff(local_val, default_val):
    """
    Recursively compares local and default values using ruamel types.
    Returns a structure containing only the differences, preserving local order.
    Returns None if there is no difference at this level.
    """
    # If types differ, the local value is the difference (if not None)
    # Note: ruamel might load simple types as special instances,
    # type() comparison might be too strict. Use isinstance if needed,
    # but direct != comparison often works for primitives.
    # Let's refine type comparison slightly.
    local_is_map = isinstance(local_val, (CommentedMap, dict))
    default_is_map = isinstance(default_val, (CommentedMap, dict))
    local_is_seq = isinstance(local_val, (CommentedSeq, list))
    default_is_seq = isinstance(default_val, (CommentedSeq, list))

    # If structures fundamentally differ (map vs list vs scalar)
    if (local_is_map != default_is_map) or (local_is_seq != default_is_seq):
        # Keep the local value if it exists
        return local_val if local_val is not None else None

    # --- Recursive comparison based on type ---

    # Dictionaries/Maps (preserve order from local_val)
    if local_is_map:
        # Use CommentedMap for the diff to preserve order
        diff_dict = CommentedMap()
        # Iterate using local keys first to preserve order
        for key in local_val:  # Iterating CommentedMap preserves order
            local_item = local_val[key]
            default_item = default_val.get(key)  # Use .get for safety

            if key not in default_val:  # Key added locally
                if (
                    local_item is not None
                ):  # Don't add explicit nulls if default didn't have key
                    diff_dict[key] = (
                        local_item  # Assign directly preserves ruamel type/comments
                    )
            else:  # Key exists in both, compare recursively
                sub_diff = compare_and_extract_diff(local_item, default_item)
                if sub_diff is not None:
                    diff_dict[key] = sub_diff  # Assign diff result

        # If diff_dict is empty, return None
        return diff_dict if diff_dict else None

    # Lists/Sequences - Helm overrides usually replace the entire list
    elif local_is_seq:
        # Simple comparison: if lists differ content-wise, keep the local one entirely.
        # ruamel sequences compared with != should work for content comparison.
        if local_val != default_val:
            # Assign directly to preserve ruamel type/comments
            return local_val
        else:
            return None

    # Primitive types (int, float, str, bool, None, etc.)
    else:
        if local_val != default_val:
            # Assign directly
            return local_val
        else:
            return None


# --- Main Execution ---


def main():
    parser = argparse.ArgumentParser(
        description="Compare a local Helm values file against the chart's defaults "
        "and output only the changed/added values, preserving order.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    # ... (Arguments remain the same as before) ...
    parser.add_argument("local_values_file", help="Path to the local values.yaml file.")
    parser.add_argument(
        "--repo", required=True, help="Helm chart repository URL or alias."
    )
    parser.add_argument(
        "--chart", required=True, help="Helm chart name (e.g., 'prometheus')."
    )
    parser.add_argument("--version", required=True, help="Helm chart version.")
    parser.add_argument(
        "-o",
        "--output",
        help="Output file path. If not specified, prints to standard output.",
    )
    parser.add_argument(
        "--add-repo",
        action="store_true",
        help="Attempt to 'helm repo add <repo_name> <repo_url>' before fetching values. "
        "Assumes --repo is 'name=url' or fails if repo not found.",
    )
    parser.add_argument(
        "--update-repo",
        action="store_true",
        help="Run 'helm repo update' before fetching values.",
    )

    args = parser.parse_args()

    repo_name_arg = args.repo
    chart_ref = f"{args.repo}/{args.chart}"

    # ... (Repo add/update logic remains the same) ...
    if args.add_repo:
        repo_parts = args.repo.split("=", 1)
        if len(repo_parts) == 2:
            repo_name, repo_url = repo_parts
            print(
                f"\nAttempting to add Helm repository '{repo_name}'...", file=sys.stderr
            )
            run_helm_command(["repo", "add", repo_name, repo_url])
            chart_ref = f"{repo_name}/{args.chart}"  # Use the added repo name now
            print(f"Using chart reference: {chart_ref}", file=sys.stderr)
        else:
            print(
                f"Warning: --add-repo specified but --repo '{args.repo}' is not in 'name=url' format. "
                f"Assuming '{args.repo}' is an existing repo name or URL.",
                file=sys.stderr,
            )

    if args.update_repo:
        print("\nUpdating Helm repositories...", file=sys.stderr)
        run_helm_command(["repo", "update"])

    # 1. Retrieve default values
    print(
        f"\nFetching default values for {chart_ref} version {args.version}...",
        file=sys.stderr,
    )
    helm_values_cmd = ["show", "values", chart_ref, "--version", args.version]
    default_values_yaml_str = run_helm_command(helm_values_cmd)
    print("Parsing default values...", file=sys.stderr)
    default_values = load_yaml_data(
        default_values_yaml_str, filepath=f"defaults:{chart_ref}:{args.version}"
    )
    print("Default values loaded.", file=sys.stderr)

    # 2. Load local values
    print(f"\nLoading local values from {args.local_values_file}...", file=sys.stderr)
    try:
        with open(args.local_values_file, "r", encoding="utf-8") as f:
            local_values = load_yaml_data(f, filepath=args.local_values_file)
        print("Local values loaded successfully.", file=sys.stderr)
    except FileNotFoundError:
        print(
            f"Error: Local values file not found: {args.local_values_file}",
            file=sys.stderr,
        )
        sys.exit(1)
    except Exception as e:  # Catch other file errors
        print(f"Error reading file {args.local_values_file}: {e}", file=sys.stderr)
        sys.exit(1)

    # 3. Compare and extract differences
    print("\nComparing values and extracting differences...", file=sys.stderr)
    diff_values = compare_and_extract_diff(local_values, default_values)
    print("Comparison complete.", file=sys.stderr)

    # 4. Output the result using ruamel.yaml
    output_generated = False
    if diff_values is not None and (
        (isinstance(diff_values, (CommentedMap, dict)) and diff_values)
        or (isinstance(diff_values, (CommentedSeq, list)) and diff_values)
        or (not isinstance(diff_values, (CommentedMap, dict, CommentedSeq, list)))
    ):
        # Condition checks if diff_values is not None AND (it's a non-empty map OR it's a non-empty sequence OR it's a scalar value)
        output_generated = True

    if not output_generated:
        print(
            "\nNo differences found between local values and defaults.", file=sys.stderr
        )
        if args.output:
            print(f"Writing empty output file to {args.output}", file=sys.stderr)
            try:
                with open(args.output, "w", encoding="utf-8") as f:
                    f.write("")  # Write an empty file
            except IOError as e:
                print(f"Error writing empty file {args.output}: {e}", file=sys.stderr)
                # Decide if this is a fatal error or not. Non-fatal for now.
        else:
            print("(No output generated)", file=sys.stderr)
        return  # Exit successfully

    # Prepare ruamel.yaml dumper
    yaml_out = YAML()
    yaml_out.indent(mapping=2, sequence=4, offset=2)  # Standard YAML indentation
    yaml_out.preserve_quotes = True  # Preserve quotes from original where possible
    yaml_out.width = 4096  # Set a very large width to prevent line wrapping

    print("\nDifferences identified:", file=sys.stderr)

    # Prepare header comment
    header = (
        f"# Values overriding chart defaults\n"
        f"# Generated by helm-values-differ script\n"
        f"# Chart: {chart_ref}:{args.version}\n"
        f"# Based on local file: {args.local_values_file}\n"
        f"---\n"
    )

    if args.output:
        print(f"Writing differences to {args.output}", file=sys.stderr)
        try:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(header)
                yaml_out.dump(diff_values, f)  # Dump directly to file stream
            print("Output file written successfully.", file=sys.stderr)
        except IOError as e:
            print(f"Error writing output file {args.output}: {e}", file=sys.stderr)
            sys.exit(1)
        except Exception as e:  # Catch ruamel errors during dump
            print(f"Error dumping YAML to {args.output}: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print("\n--- Start of Diff Output ---", file=sys.stderr)
        print(header, end="")  # Print header without extra newline
        # Dump to a string buffer and then print, to ensure it goes to stdout
        string_stream = io.StringIO()
        yaml_out.dump(diff_values, string_stream)
        print(
            string_stream.getvalue(), end=""
        )  # Print dumped yaml without extra newline
        string_stream.close()
        print("--- End of Diff Output ---", file=sys.stderr)


if __name__ == "__main__":
    main()
