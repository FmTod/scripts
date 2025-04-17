import argparse
import subprocess
import sys
import yaml
from copy import deepcopy

# --- Configuration ---
# You might need to adjust this if 'helm' is not in your PATH
HELM_EXECUTABLE = "helm"

# --- Helper Functions ---


def run_helm_command(args_list):
    """Runs a Helm command and returns its stdout."""
    command = [HELM_EXECUTABLE] + args_list
    try:
        print(f"Running command: {' '.join(command)}", file=sys.stderr)
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=True,  # Raises CalledProcessError on non-zero exit code
            encoding="utf-8",
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
        print(f"Stdout: {e.stdout}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"An unexpected error occurred: {e}", file=sys.stderr)
        sys.exit(1)


def load_yaml_file(filepath):
    """Loads YAML data from a file."""
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        print(f"Error: Local values file not found: {filepath}", file=sys.stderr)
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"Error parsing YAML file {filepath}: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error reading file {filepath}: {e}", file=sys.stderr)
        sys.exit(1)


def compare_and_extract_diff(local_val, default_val):
    """
    Recursively compares local and default values.
    Returns a structure containing only the differences introduced by local_val.
    Returns None if there is no difference at this level.
    """
    # If the types are different, the entire local value is considered a difference
    if type(local_val) != type(default_val):
        # Handle cases where one might be None (e.g., key added in local)
        if local_val is not None:
            return deepcopy(local_val)
        else:
            # This case (local is None but default exists) shouldn't typically
            # result in keeping the None, unless explicitly set. Usually,
            # if a default exists and local doesn't override, it's not a diff.
            return None  # No difference to *keep* from local

    # --- Recursive comparison based on type ---

    # Dictionaries
    if isinstance(local_val, dict):
        diff_dict = {}
        all_keys = set(local_val.keys()) | set(default_val.keys())

        for key in all_keys:
            local_item = local_val.get(key)
            default_item = default_val.get(key)

            if key not in default_val:
                # Key added in local values
                if local_item is not None:  # Don't add explicit nulls unless intended
                    diff_dict[key] = deepcopy(local_item)
            elif key not in local_val:
                # Key exists in default but removed (or not specified) in local.
                # This script aims to *keep* local overrides, so we don't mark this as a diff to keep.
                pass
            else:
                # Key exists in both, compare recursively
                sub_diff = compare_and_extract_diff(local_item, default_item)
                if sub_diff is not None:
                    diff_dict[key] = sub_diff

        return diff_dict if diff_dict else None  # Return dict only if it has content

    # Lists - Helm overrides usually replace the entire list
    elif isinstance(local_val, list):
        # Simple comparison: if lists are different, keep the local one entirely.
        # More complex list diffing (element-wise) is possible but often not
        # what's intended with Helm value overrides.
        if local_val != default_val:
            return deepcopy(local_val)
        else:
            return None

    # Primitive types (int, float, str, bool, None)
    else:
        if local_val != default_val:
            # Use deepcopy for mutable primitives? Generally not needed for immutables.
            # But safer if complex objects were ever treated as primitives.
            return deepcopy(local_val)
        else:
            return None


# --- Main Execution ---


def main():
    parser = argparse.ArgumentParser(
        description="Compare a local Helm values file against the chart's defaults "
        "and output only the changed/added values.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
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

    repo_name_arg = args.repo  # Could be URL or name
    chart_ref = f"{args.repo}/{args.chart}"  # Helm command needs repo/chart format

    # Handle optional repo add/update
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
            # Proceed assuming args.repo is usable directly

    if args.update_repo:
        print("\nUpdating Helm repositories...", file=sys.stderr)
        run_helm_command(["repo", "update"])

    # 1. Retrieve default values
    print(
        f"\nFetching default values for {chart_ref} version {args.version}...",
        file=sys.stderr,
    )
    helm_values_cmd = ["show", "values", chart_ref, "--version", args.version]
    default_values_yaml = run_helm_command(helm_values_cmd)

    try:
        default_values = yaml.safe_load(default_values_yaml)
        if default_values is None:  # Handle empty default values
            default_values = {}
        print("Default values loaded successfully.", file=sys.stderr)
    except yaml.YAMLError as e:
        print(f"Error parsing default values YAML from Helm: {e}", file=sys.stderr)
        sys.exit(1)

    # 2. Load local values
    print(f"\nLoading local values from {args.local_values_file}...", file=sys.stderr)
    local_values = load_yaml_file(args.local_values_file)
    if local_values is None:  # Handle empty local file
        local_values = {}
    print("Local values loaded successfully.", file=sys.stderr)

    # 3. Compare and extract differences
    print("\nComparing values and extracting differences...", file=sys.stderr)
    diff_values = compare_and_extract_diff(local_values, default_values)
    print("Comparison complete.", file=sys.stderr)

    # 4. Output the result
    output_yaml = ""
    if (
        diff_values is not None and diff_values
    ):  # Ensure there are differences to output
        try:
            output_yaml = yaml.dump(
                diff_values,
                indent=2,
                default_flow_style=False,
                sort_keys=False,  # Try to preserve key order where possible
            )
        except yaml.YAMLError as e:
            print(f"Error formatting output YAML: {e}", file=sys.stderr)
            sys.exit(1)

    if not output_yaml:
        print(
            "\nNo differences found between local values and defaults.", file=sys.stderr
        )
        # Decide if an empty file should be written or not
        if args.output:
            print(f"Writing empty output file to {args.output}", file=sys.stderr)
            with open(args.output, "w", encoding="utf-8") as f:
                f.write("")  # Write an empty file
        else:
            print("(No output generated)", file=sys.stderr)
        return  # Exit successfully

    print("\nDifferences identified:", file=sys.stderr)
    if args.output:
        print(f"Writing differences to {args.output}", file=sys.stderr)
        try:
            with open(args.output, "w", encoding="utf-8") as f:
                # Add a comment header (optional)
                f.write("# Values overriding chart defaults\n")
                f.write("# Generated by helm-values-differ script\n")
                f.write(f"# Chart: {chart_ref}:{args.version}\n")
                f.write(f"# Based on local file: {args.local_values_file}\n")
                f.write("---\n")
                f.write(output_yaml)
            print("Output file written successfully.", file=sys.stderr)
        except IOError as e:
            print(f"Error writing output file {args.output}: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print("\n--- Start of Diff Output ---", file=sys.stderr)
        # Add comment header to stdout as well
        print("# Values overriding chart defaults")
        print("# Generated by helm-values-differ script")
        print(f"# Chart: {chart_ref}:{args.version}")
        print(f"# Based on local file: {args.local_values_file}")
        print("---")
        print(output_yaml)
        print("--- End of Diff Output ---", file=sys.stderr)


if __name__ == "__main__":
    main()
