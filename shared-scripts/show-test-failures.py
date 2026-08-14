"""
This script parses xcresult bundles and displays test failure information
in GitHub Actions logs and as annotations for inline PR visibility.
"""

import os
import sys

from log_scope import scoped_log_entries
from xcresult_failures import format_test_identifier, get_test_failures

MAX_MESSAGE_LENGTH = 500


def truncate_message(message, max_length=MAX_MESSAGE_LENGTH):
    """Truncate message to max length with ellipsis if needed."""
    if len(message) <= max_length:
        return message
    return message[: max_length - 3] + "..."


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


def main():
    """Main entry point - report the failures of the current invocation."""
    xcresult_path_arg = sys.argv[1] if len(sys.argv) > 1 else None

    all_failures = []

    if xcresult_path_arg and xcresult_path_arg.endswith(".xcresult"):
        if os.path.exists(xcresult_path_arg):
            all_failures.extend(get_test_failures(xcresult_path_arg))
    else:
        # Only the bundles this invocation wrote; an earlier platform step's results are
        # still in the shared log directory and are not this step's failures to report.
        for path, name in scoped_log_entries():
            if name.endswith(".xcresult"):
                all_failures.extend(get_test_failures(path))

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
