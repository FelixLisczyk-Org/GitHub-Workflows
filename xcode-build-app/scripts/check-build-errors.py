"""
This script checks the Xcode build logs for internal errors (like build system crashes)
and writes the result into the GitHub Actions workflow environment file.
This allows CI builds to determine if a build should be retried.
"""

import os

retry_errors = ["The Xcode build system has crashed", "Command CodeSign failed with a nonzero exit code"]

for log_file_name in os.listdir("log"):
    if ".log" in log_file_name:
        log_file = open(f"log/{log_file_name}", "r")
        log_file_contents = log_file.read()

        for retry_error in retry_errors:
            if retry_error in log_file_contents:
                print(f"Found known build error: {retry_error}")
                env_file_path = os.getenv("GITHUB_ENV")
                if env_file_path:
                    with open(env_file_path, "a") as f:
                        f.write("RETRY_BUILD=true")
                exit(0)
