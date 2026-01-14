"""
This script parses xcresult bundles and displays test failure information
in GitHub Actions logs and as annotations for inline PR visibility.
"""

import json
import os
import subprocess
import sys

MAX_MESSAGE_LENGTH = 500


def get_test_results(xcresult_path):
    """Extract test results from xcresult file using xcresulttool."""
    try:
        result = subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "tests",
                "--path",
                xcresult_path,
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        )
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Warning: Failed to get test results from {xcresult_path}: {e.stderr}", file=sys.stderr)
        return None
    except subprocess.TimeoutExpired:
        print(f"Warning: Timeout while getting test results from {xcresult_path}", file=sys.stderr)
        return None
    except json.JSONDecodeError as e:
        print(f"Warning: Failed to parse test results JSON from {xcresult_path}: {e}", file=sys.stderr)
        return None


def build_device_map(data):
    """Build a mapping from deviceId to device name."""
    device_map = {}
    for device in data.get("devices", []):
        device_id = device.get("deviceId")
        device_name = device.get("deviceName", "Unknown Device")
        os_version = device.get("osVersion", "")
        if device_id:
            if os_version:
                device_map[device_id] = f"{device_name} ({os_version})"
            else:
                device_map[device_id] = device_name
    return device_map


def truncate_message(message, max_length=MAX_MESSAGE_LENGTH):
    """Truncate message to max length with ellipsis if needed."""
    if len(message) <= max_length:
        return message
    return message[: max_length - 3] + "..."


def extract_failures(node, path=None, device_name=None, failures=None):
    """
    Recursively extract test failures from test node tree.
    Returns a list of failure dictionaries with test path, message, and device.
    """
    if failures is None:
        failures = []
    if path is None:
        path = []

    node_type = node.get("nodeType", "")
    node_name = node.get("name", "")
    result = node.get("result", "")
    children = node.get("children", [])

    # Track current device if this is a Device node
    current_device = device_name
    if node_type == "Device":
        current_device = node_name

    # Build path for test hierarchy (skip non-test nodes like Device, Configuration)
    current_path = path
    if node_type in ["Unit test bundle", "UI test bundle", "Test Suite", "Test Case"]:
        current_path = path + [node_name]

    # Check for failure message nodes
    if node_type == "Failure Message":
        # Get the failure details (assertion message)
        failure_message = node.get("details", node_name)
        if current_path:
            failures.append(
                {
                    "path": current_path,
                    "message": failure_message,
                    "device": current_device,
                }
            )

    # Recurse into children
    for child in children:
        extract_failures(child, current_path, current_device, failures)

    return failures


def format_test_identifier(path):
    """Format test path as a readable identifier (e.g., TestTarget/TestClass/testMethod)."""
    return "/".join(path)


def output_github_annotation(failure):
    """Output a GitHub Actions error annotation for a test failure."""
    test_id = format_test_identifier(failure["path"])
    message = truncate_message(failure["message"])
    device = failure.get("device", "")

    # Format: ::error title=<title>::<message>
    title = test_id
    if device:
        annotation_message = f"[{device}] {message}"
    else:
        annotation_message = message

    # Escape special chars for GitHub annotations
    annotation_message = (
        annotation_message
        .replace("%", "%25")
        .replace("\r", "%0D")
        .replace("\n", "%0A")
    )

    print(f"::error title={title}::{annotation_message}")


def output_plain_text_summary(failures):
    """Output a plain text summary of all test failures."""
    if not failures:
        return

    print("\n" + "=" * 60)
    print("TEST FAILURES SUMMARY")
    print("=" * 60)

    for i, failure in enumerate(failures, 1):
        test_id = format_test_identifier(failure["path"])
        message = truncate_message(failure["message"])
        device = failure.get("device", "")

        print(f"\n{i}. {test_id}")
        if device:
            print(f"   Device: {device}")
        print(f"   Message: {message}")

    print("\n" + "=" * 60)
    print(f"Total failures: {len(failures)}")
    print("=" * 60 + "\n")


def process_xcresult(xcresult_path):
    """Process a single xcresult file and return failures found."""
    data = get_test_results(xcresult_path)
    if not data:
        return []

    device_map = build_device_map(data)
    failures = []

    for test_node in data.get("testNodes", []):
        node_failures = extract_failures(test_node)
        failures.extend(node_failures)

    # Resolve device names from device map if needed
    for failure in failures:
        device = failure.get("device", "")
        if device and device in device_map:
            failure["device"] = device_map[device]

    return failures


def main():
    """Main entry point - scan log directory for xcresult files."""
    log_dir = "log"
    xcresult_path_arg = sys.argv[1] if len(sys.argv) > 1 else None

    all_failures = []

    if xcresult_path_arg and xcresult_path_arg.endswith(".xcresult"):
        if os.path.exists(xcresult_path_arg):
            failures = process_xcresult(xcresult_path_arg)
            all_failures.extend(failures)
    elif os.path.exists(log_dir):
        for file_name in os.listdir(log_dir):
            if file_name.endswith(".xcresult"):
                xcresult_path = os.path.join(log_dir, file_name)
                failures = process_xcresult(xcresult_path)
                all_failures.extend(failures)

    if not all_failures:
        # Silent exit if no failures found
        return

    # Output GitHub Actions annotations
    for failure in all_failures:
        output_github_annotation(failure)

    # Output plain text summary
    output_plain_text_summary(all_failures)


if __name__ == "__main__":
    main()
