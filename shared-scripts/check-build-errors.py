"""
This script checks the Xcode build logs for internal errors (like build system crashes)
and writes the result into the GitHub Actions workflow environment file.
This allows CI builds to determine if a build should be retried.

Only the logs written by the current invocation are analysed (see `log_scope`), and a
retry is only offered when nothing in the results looks like a genuine test failure -
those never heal on a rerun, so recovering from one just multiplies the wall-clock cost
of a red build.
"""

import json
import os
import re
import subprocess
import sys

from log_scope import LOG_DIR, scoped_log_entries
from xcresult_failures import format_test_identifier, get_test_failures, truncate_message

clear_derived_data_errors = [
    "Underlying Error: Test crashed with signal abrt before starting test execution.",
    "compiled with an older version of the compiler",  # Compiler version too new
    "cannot be imported by the Swift",  # Compiler version too old, e.g. 'Module compiled with Swift 6.2 cannot be imported by the Swift 6.1.2 compiler'
    "mtime changed",  # Stale module cache after Xcode update
    "tapi error: missing required architecture",  # Stale TBD file in EagerLinkingTBDs missing architecture slice
]

# A compiler or linker diagnostic naming a build input that is missing from DerivedData,
# e.g. `ld: ... no such file or directory: '<DerivedData>/.../cmark_gfm.framework/cmark_gfm'`
# or `clang: error: no such file or directory: 'Foo.swift'`. Such a diagnostic always names
# the missing path after a colon, which is what separates it from the benign OS chatter
# xctest writes into the same build log:
#   [cloudthumbnails.client] getattrlist() failed for file:///... - No such file or directory
#   [logging-persist] os_unix.c:51044: (2) open(/private/var/db/DetachedSignatures) - No such file or directory
#   fopen failed for data file: errno = 2 (No such file or directory)
# Matching those as a bare substring made a passing platform's log trigger a 17-minute
# Tuist cache rebuild and a full lane rerun on an unrelated platform.
missing_build_input_error = re.compile(r"no such file or directory:\s*\S", re.IGNORECASE)

clear_derived_data_and_tuist_cache_errors = [
    "ld: symbol(s) not found",
    missing_build_input_error,  # Missing file in DerivedData after dependency update; often caused by stale Tuist cache
    "Undefined symbol: type metadata accessor",
    # Stale DerivedData/Tuist cache breaks an SPM package's generated module map (e.g. cmark-gfm),
    # interrupting the test action before it starts. Matched both with and without the shell-style
    # backslash-escaped space, since the escaping isn't consistent across xcodebuild output formats.
    "PhaseScriptExecution Copy\\ Module\\ Map",
    "PhaseScriptExecution Copy Module Map",
]

simulator_errors = [
    "The test runner failed to initialize for UI testing",
    "The test runner timed out while preparing to run tests",
    # XCUITest-specific failures (SN-317)
    "Failed to perform AX action",
    "App failed to quiesce within",
    "Failed to establish communication with the test runner",
    "Failed to install or launch the test runner",
    "Test crashed with signal kill",
    "UI Testing Failure - Failed to perform AX action for monitoring the animations",
    "kAXErrorServerNotFound",
    "after 30 retries: kAXError",
    "UI Testing Failure - App failed to quiesce",
    "Test session exited",
    "Unable to run test class",
    "Connection interrupted",
    "Application failed preflight checks",  # Simulator busy/locked during app launch
    "log hasn't finished recording after waiting",  # Result bundle log write timeout
    "Simulator device failed to install the application",
]

clear_tuist_cache_errors = ["Underlying Error: Crash", "Failed to load the test bundle"]

recreate_simulators_errors = [
    "Unable to boot device because it cannot be located on disk",
    "The test runner hung before establishing connection",
    # Corrupt simulator install database (IXPlaceholder state) — the partial reset in
    # handle_simulator_error is insufficient (the placeholder error reappears on retry),
    # so the simulators must be recreated from scratch. Checked before simulator_errors,
    # which would otherwise match the surrounding "Failed to install or launch the test
    # runner" message and trigger only the lighter reset.
    "Failed to create app extension placeholder",
    "Placeholder did not exist",
]

retry_errors = [
    "The Xcode build system has crashed",
    "Command CodeSign failed with a nonzero exit code",
    "Segmentation fault",
    "error: stat",
]


def handle_derived_data_and_tuist_cache_error(err):
    """Handle linker errors by clearing both Xcode derived data and Tuist cache"""
    print(f"Found linker error requiring derived data and tuist cache clearing: {err}")
    os.system(f"{os.path.dirname(__file__)}/clear-xcode-derived-data.sh")
    tuist_cache_path = os.path.expanduser("~/.cache/tuist")
    if os.path.exists(tuist_cache_path):
        print(f"Clearing global tuist cache at {tuist_cache_path}")
        os.system(f"rm -rf {tuist_cache_path}")
    project_tuist_path = "Tuist/.build"
    cache_marker_path = os.path.join(project_tuist_path, ".package-resolved-hash")
    if os.path.exists(project_tuist_path):
        print(f"Clearing project tuist cache at {project_tuist_path}")
        os.system(f"rm -rf {project_tuist_path}")
    if os.path.exists(cache_marker_path):
        print(f"Clearing project tuist cache marker at {cache_marker_path}")
        os.system(f"rm -f {cache_marker_path}")
    if os.path.exists("Tuist.swift"):
        print("Regenerating tuist cache")
        os.system("tuist install && tuist cache && tuist generate --no-open")
    set_retry_build()


def handle_derived_data_error(err):
    """Handle derived data errors by clearing Xcode derived data"""
    print(f"Found error that requires cleaning derived data: {err}")
    os.system(f"{os.path.dirname(__file__)}/clear-xcode-derived-data.sh")
    set_retry_build()


def handle_simulator_error(err):
    """Handle simulator errors by quitting Xcode, Simulator, Instruments, killing CoreSimulatorService, and removing CoreSimulator data"""
    print(f"Found simulator error: {err}")
    commands = [
        "osascript -e 'quit app \"Xcode\"'",
        "osascript -e 'quit app \"Simulator\"'",
        "osascript -e 'quit app \"Instruments\"'",
        "killall -9 com.apple.CoreSimulator.CoreSimulatorService",
        "rm -rf ~/Library/Xcode/CoreSimulator",
    ]
    for cmd in commands:
        print(f"Executing: {cmd}")
        os.system(cmd)
    set_retry_build()


def handle_recreate_simulators_error(err):
    """Handle corrupt simulator errors by quitting Xcode, Simulator, Instruments, killing CoreSimulatorService, killing stale DTServiceHub processes, and removing the entire CoreSimulator directory so simulators are recreated fresh"""
    print(f"Found simulator error requiring full recreate: {err}")
    commands = [
        "osascript -e 'quit app \"Xcode\"'",
        "osascript -e 'quit app \"Simulator\"'",
        "osascript -e 'quit app \"Instruments\"'",
        "killall -9 com.apple.CoreSimulator.CoreSimulatorService",
        "killall -9 DTServiceHub",
        "rm -rf ~/Library/Developer/CoreSimulator",
    ]
    for cmd in commands:
        print(f"Executing: {cmd}")
        os.system(cmd)
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
    cache_marker_path = os.path.join(project_tuist_path, ".package-resolved-hash")
    if os.path.exists(project_tuist_path):
        print(f"Clearing project tuist cache at {project_tuist_path}")
        os.system(f"rm -rf {project_tuist_path}")
    else:
        print(f"Project tuist cache not found at {project_tuist_path}")
    if os.path.exists(cache_marker_path):
        print(f"Clearing project tuist cache marker at {cache_marker_path}")
        os.system(f"rm -f {cache_marker_path}")
    print("Regenerating tuist cache")
    os.system("tuist install && tuist cache && tuist generate --no-open")
    set_retry_build()


def handle_regular_error(err):
    """Handle regular retry errors"""
    print(f"Found build error that requires retry: {err}")
    set_retry_build()


# Ordered highest-priority first; the first category to match wins.
handlers = [
    # Linker errors that require clearing both derived data and tuist cache
    (clear_derived_data_and_tuist_cache_errors, handle_derived_data_and_tuist_cache_error),
    # Errors that require clearing derived data
    (clear_derived_data_errors, handle_derived_data_error),
    # Errors that require recreating simulators from scratch
    (recreate_simulators_errors, handle_recreate_simulators_error),
    # Errors that require a simulator reset
    (simulator_errors, handle_simulator_error),
    # Errors that require clearing tuist cache
    (clear_tuist_cache_errors, handle_tuist_cache_error),
    # Regular retry errors
    (retry_errors, handle_regular_error),
]


MAX_EXCERPT_LENGTH = 300


def excerpt(text, start, end):
    """The matched text widened to its whole line, and trimmed if that line is huge.

    Reporting the offending line rather than the pattern that caught it makes the CI log
    self-explanatory: the reader sees the actual diagnostic instead of a regex.
    """
    line_start = text.rfind("\n", 0, start) + 1
    line_end = text.find("\n", end)
    if line_end == -1:
        line_end = len(text)
    line = text[line_start:line_end].strip()
    if len(line) > MAX_EXCERPT_LENGTH:
        line = line[: MAX_EXCERPT_LENGTH - 3] + "..."
    return line


def find_handler(text):
    """Return the `(excerpt, handler)` of the highest-priority category matching `text`.

    Priority is applied globally across the whole text, not per message. Xcode can emit
    multiple errorSummaries for one failure (e.g. a short "Simulator device failed to
    install the application" alongside a long "Placeholder did not exist" message). Since
    the first matched handler calls set_retry_build() -> sys.exit(0), matching per message
    would let an earlier, lower-priority message win over a later, higher-priority one.
    Checking the categories in priority order against the joined text ensures the correct
    handler runs regardless of message order.

    Plain string patterns match as case-insensitive substrings; compiled patterns are
    matched as regular expressions, for the cases where a substring is too blunt to
    separate a real diagnostic from log noise.
    """
    # Lowered once rather than per pattern: build logs routinely reach tens of megabytes.
    lowered = text.lower()
    for error_list, handler in handlers:
        for pattern in error_list:
            if isinstance(pattern, re.Pattern):
                match = pattern.search(text)
                if match:
                    return excerpt(text, match.start(), match.end()), handler
            else:
                index = lowered.find(pattern.lower())
                if index != -1:
                    return excerpt(text, index, index + len(pattern)), handler
    return None, None


def process_errors(error_messages):
    """Process error messages and handle the single highest-priority match."""
    # Accept both string and list input
    if isinstance(error_messages, str):
        error_messages = [error_messages]
    matched, handler = find_handler("\n".join(error_messages))
    if handler:
        handler(matched)  # calls set_retry_build() -> sys.exit(0)


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


def collect_test_failures(entries):
    """Return every test failure recorded by the xcresult bundles of this invocation."""
    failures = []
    for path, name in entries:
        if name.endswith(".xcresult"):
            failures.extend(get_test_failures(path))
    return failures


def find_genuine_test_failures(failures):
    """Return the test failures that no infrastructure pattern explains.

    A failing assertion produces the same failure on every rerun, so clearing caches and
    replaying the lane only multiplies the wall-clock cost of a build that was always going
    to be red. Failures that *are* infrastructure - a crashed test runner, a bundle that
    could not be loaded - match one of the categories above and still reach their handler.
    """
    return [failure for failure in failures if find_handler(failure["message"])[1] is None]


def group_failures_by_test(failures):
    """Group failure messages under the test that produced them, keeping first-seen order.

    Xcode's `retry_failed_tests` reruns a failing test within the same invocation, so a
    single flaky test contributes one failure entry per attempt. Counting those entries
    reports one failing test as two; grouping by test identifier counts tests instead, and
    identical messages from the reruns collapse into the one line they always were.
    """
    grouped = {}
    for failure in failures:
        test_id = format_test_identifier(failure["path"])
        details = (failure.get("device", ""), failure["message"])
        messages = grouped.setdefault(test_id, [])
        if details not in messages:
            messages.append(details)
    return grouped


def format_failure_message(device, message):
    """Indent an assertion message under its test, tagged with the device that ran it."""
    prefix = f"[{device}] " if device else ""
    lines = truncate_message(message).splitlines() or [""]
    first, rest = lines[0], lines[1:]
    return "\n".join([f"      {prefix}{first}"] + [f"      {line}" for line in rest])


def report_genuine_test_failures(failures):
    """Explain why no retry is offered, so the abort that follows isn't a mystery."""
    grouped = group_failures_by_test(failures)
    print(f"Found {len(grouped)} failing test(s) unrelated to build infrastructure; skipping retry.")
    print("A retry cannot fix a failing test, so the build is failed immediately instead.")
    # The assertion message, not just the test name: without it the log says which test broke
    # but never why, and the xcresult that holds the answer lives only on the runner.
    for test_id, messages in grouped.items():
        print(f"  - {test_id}")
        for device, message in messages:
            print(format_failure_message(device, message))


def set_retry_build():
    """Set RETRY_BUILD flag in GitHub environment"""
    env_file_path = os.getenv("GITHUB_ENV")
    if env_file_path:
        with open(env_file_path, "a", encoding="utf-8") as f:
            f.write("RETRY_BUILD=true")
    sys.exit(0)


def main():
    if not os.path.isdir(LOG_DIR):
        print(f"Error: '{LOG_DIR}' directory not found in {os.getcwd()}")
        return

    entries = scoped_log_entries()
    if not entries:
        # The invocation failed before writing anything, so there is nothing to classify and
        # no basis for a retry. Say so rather than exiting silently into an unexplained abort.
        print(f"No {LOG_DIR}/ entries were written by this invocation; nothing to analyse.")
        return

    test_failures = collect_test_failures(entries)
    genuine_test_failures = find_genuine_test_failures(test_failures)
    if genuine_test_failures:
        report_genuine_test_failures(genuine_test_failures)
        return

    for path, name in entries:
        if name.endswith(".log"):
            with open(path, "r", encoding="utf-8", errors="replace") as log_file:
                process_errors(log_file.read())
        elif name.endswith(".xcresult"):
            process_errors(get_xcresult_errors(path))

    # Nothing in the build log or the error summaries explained the failure, but every test
    # failure above was classified as infrastructure. Analyse those messages too rather than
    # abort, for the cases where the only trace of a flaky runner is the failure it produced.
    if test_failures:
        process_errors([failure["message"] for failure in test_failures])


if __name__ == "__main__":
    main()
