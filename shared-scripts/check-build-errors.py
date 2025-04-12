"""
This script checks the Xcode build logs for internal errors (like build system crashes)
and writes the result into the GitHub Actions workflow environment file.
This allows CI builds to determine if a build should be retried.
"""

import json
import os
import subprocess
import sys

retry_errors = [
    "The Xcode build system has crashed",
    "Command CodeSign failed with a nonzero exit code",
    "The test runner failed to initialize for UI testing",
    "Segmentation fault",
    "error: stat",
]

clear_derived_data_errors = ["ld: symbol(s) not found"]

clear_tuist_cache_errors = ["Underlying Error: Crash", "Failed to load the test bundle"]


def set_retry_build():
    """Set RETRY_BUILD flag in GitHub environment"""
    env_file_path = os.getenv("GITHUB_ENV")
    if env_file_path:
        with open(env_file_path, "a", encoding="utf-8") as f:
            f.write("RETRY_BUILD=true")
    sys.exit(0)


def handle_derived_data_error(err):
    """Handle derived data errors by clearing Xcode derived data"""
    print(f"Found error that requires cleaning derived data: {err}")
    os.system(f"{os.path.dirname(__file__)}/clear-xcode-derived-data.sh")
    set_retry_build()


def handle_tuist_cache_error(err):
    """Handle tuist cache errors by clearing the cache"""
    print(f"Found error that requires clearing tuist cache: {err}")
    tuist_cache_path = os.path.expanduser("~/.cache/tuist")
    if os.path.exists(tuist_cache_path):
        print(f"Clearing global tuist cache at {tuist_cache_path}")
        os.system(f"rm -rf {tuist_cache_path}")
    else:
        print(f"Global tuist cache not found at {tuist_cache_path}")
    project_tuist_path = "Tuist/.build"
    if os.path.exists(project_tuist_path):
        print(f"Clearing project tuist cache at {project_tuist_path}")
        os.system(f"rm -rf {project_tuist_path}")
    else:
        print(f"Project tuist cache not found at {project_tuist_path}")
    print("Regenerating tuist cache")
    os.system("tuist install && tuist cache && tuist generate --no-open")
    set_retry_build()


def handle_regular_error(err):
    """Handle regular retry errors"""
    print(f"Found build error that requires retry: {err}")
    set_retry_build()


def process_errors(error_messages):
    """Process a list of error messages and handle them based on priority"""
    for error_message in error_messages:
        # Check for errors that require clearing derived data
        for error in clear_derived_data_errors:
            if error in error_message:
                handle_derived_data_error(error)

        # Check for errors that require clearing tuist cache
        for error in clear_tuist_cache_errors:
            if error in error_message:
                handle_tuist_cache_error(error)

        # Check for regular retry errors
        for error in retry_errors:
            if error in error_message:
                handle_regular_error(error)


def get_xcresult_errors(xcresult_path):
    """Extract error messages from xcresult file"""
    try:
        result = subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "get",
                "--format",
                "json",
                "--path",
                xcresult_path,
                "--legacy",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        data = json.loads(result.stdout)
        errors = []
        if "issues" in data and "errorSummaries" in data["issues"]:
            for summary in data["issues"]["errorSummaries"].get("_values", []):
                if "message" in summary and "_value" in summary["message"]:
                    xcresult_error = summary["message"]["_value"]
                    print(f"Found test error in {xcresult_path}: {xcresult_error}")
                    errors.append(xcresult_error)
        return errors
    except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
        print(f"Error processing {xcresult_path}: {str(e)}")
        return []


if not os.path.exists("log"):
    print(f"Error: 'log' directory not found in {os.getcwd()}")
else:
    for file_name in os.listdir("log"):
        file_path = f"log/{file_name}"

        if file_name.endswith(".log"):
            with open(file_path, "r", encoding="utf-8") as log_file:
                log_file_contents = log_file.read()
                process_errors(log_file_contents)

        elif file_name.endswith(".xcresult"):
            process_errors(get_xcresult_errors(file_path))
