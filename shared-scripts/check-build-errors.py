"""
This script checks the Xcode build logs for internal errors (like build system crashes)
and writes the result into the GitHub Actions workflow environment file.
This allows CI builds to determine if a build should be retried.
"""

import os
import sys

retry_errors = [
    "The Xcode build system has crashed",
    "Command CodeSign failed with a nonzero exit code",
    "The test runner failed to initialize for UI testing",
    "Segmentation fault",
    "error: stat",
]

clear_derived_data_errors = ["ld: symbol(s) not found"]

clear_tuist_cache_errors = ["Underlying Error: Crash"]


def set_retry_build():
    """Set RETRY_BUILD flag in GitHub environment"""
    env_file_path = os.getenv("GITHUB_ENV")
    if env_file_path:
        with open(env_file_path, "a", encoding="utf-8") as f:
            f.write("RETRY_BUILD=true")
    sys.exit(0)


def handle_derived_data_error(err):
    """Handle derived data errors by clearing Xcode derived data"""
    print(f"Found derived data error: {err}")
    os.system(f"{os.path.dirname(__file__)}/clear-xcode-derived-data.sh")
    set_retry_build()


def handle_tuist_cache_error(err):
    """Handle tuist cache errors by clearing the cache"""
    print(f"Found tuist cache error: {err}")
    tuist_cache_path = os.path.expanduser("~/.cache/tuist")
    if os.path.exists(tuist_cache_path):
        os.system(f"rm -rf {tuist_cache_path}")
    set_retry_build()


def handle_regular_error(err):
    """Handle regular retry errors"""
    print(f"Found known build error: {err}")
    set_retry_build()


for log_file_name in os.listdir("log"):
    if ".log" in log_file_name:
        with open(f"log/{log_file_name}", "r", encoding="utf-8") as log_file:
            log_file_contents = log_file.read()

            # Check for errors that require clearing derived data
            for error in clear_derived_data_errors:
                if error in log_file_contents:
                    handle_derived_data_error(error)

            # Check for errors that require clearing tuist cache
            for error in clear_tuist_cache_errors:
                if error in log_file_contents:
                    handle_tuist_cache_error(error)

            # Check for regular retry errors
            for error in retry_errors:
                if error in log_file_contents:
                    handle_regular_error(error)
