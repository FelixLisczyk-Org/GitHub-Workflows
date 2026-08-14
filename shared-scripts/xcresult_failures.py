"""
Extracts test failures from xcresult bundles.

Shared by `show-test-failures.py`, which reports them, and `check-build-errors.py`,
which uses them to tell a genuine test failure apart from an infrastructure failure
before deciding whether a retry is worth its wall-clock cost.
"""

import json
import subprocess
import sys

XCRESULTTOOL_TIMEOUT_SECONDS = 60


def get_test_results(xcresult_path):
    """Extract test results from an xcresult bundle using xcresulttool."""
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
            timeout=XCRESULTTOOL_TIMEOUT_SECONDS,
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


def get_test_failures(xcresult_path):
    """Return every test failure recorded in a single xcresult bundle."""
    data = get_test_results(xcresult_path)
    if not data:
        return []

    device_map = build_device_map(data)
    failures = []

    for test_node in data.get("testNodes", []):
        failures.extend(extract_failures(test_node))

    # Resolve device names from device map if needed
    for failure in failures:
        device = failure.get("device", "")
        if device and device in device_map:
            failure["device"] = device_map[device]

    return failures


def format_test_identifier(path):
    """Format test path as a readable identifier (e.g., TestTarget/TestClass/testMethod)."""
    return "/".join(path)
