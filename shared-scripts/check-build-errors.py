"""
This script checks the Xcode build logs for internal errors (like build system crashes)
and writes the result into the GitHub Actions workflow environment file.
This allows CI builds to determine if a build should be retried.

Only the logs written by the current invocation are analysed (see `log_scope`), and a
retry is only offered when nothing in the results looks like a genuine test failure -
those never heal on a rerun, so recovering from one just multiplies the wall-clock cost
of a red build.

Recovery itself is scoped by PL-377: the Studio runs CI alongside agent and manual work
as the same user, so a handler may only clear state owned by the current CI workspace
and the CI-owned simulator device named in `IOS_SIMULATOR_DESTINATION`. Machine-global
operations - quitting shared apps, killing CoreSimulatorService or DTServiceHub,
deleting `~/Library/Developer/CoreSimulator` or the shared Tuist/SwiftPM caches - are
never performed; when they would have been the only effective repair, the handler logs
that and retries without destructive recovery.
"""

import json
import os
import re
import subprocess
import sys

from log_scope import LOG_DIR, scoped_log_entries
from xcresult_failures import format_test_identifier, get_test_failures, get_test_results, truncate_message

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
# Matching those as a bare substring made a passing platform's log trigger a synchronous
# Tuist binary cache warm and a full lane rerun on an unrelated platform.
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

# A bare `Crash: xctest` is a test-runner process death, not an assertion: the worker died
# instead of failing, so the message carries no stack frame and no test frame at all.
# xcodebuild then attributes the death to whichever test that worker had next queued, which
# is why the named test is routinely one that passes on every other platform and rerun.
# Treating that as a genuine failure aborts a build a retry would have recovered, so it is
# classified as infrastructure and allowed to retry.
#
# The frame is what makes the difference. `Crash: xctest at <frame>` names where the runner
# died, which is real evidence about a specific test, so only the frameless form is exempted
# here (see `crash_without_frame`).
crash_without_frame = re.compile(r"crash:\s*xctest\s*$", re.IGNORECASE)

retry_errors = [
    crash_without_frame,
    "The Xcode build system has crashed",
    "Command CodeSign failed with a nonzero exit code",
    "Segmentation fault",
    "error: stat",
]

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


# PL-376 gives agents disposable `Ticket <ID> - ...` simulators whose installed app
# and data state must survive CI. Recovery therefore refuses to touch any device
# whose name begins with that prefix, no matter which UDID the destination named.
TICKET_DEVICE_PREFIX = "Ticket "

# PL-377: the Studio runs CI and agent/manual work as the same user, so recovery may
# only mutate the failed job's own workspace and the CI-owned simulator device.
# Machine-global operations (quitting shared apps, killing CoreSimulatorService or
# DTServiceHub, deleting ~/Library/CoreSimulator or ~/.cache/tuist) are gone for good.


def destination_udid():
    """Return the simulator UDID the failed job tested against, or None.

    `xcode-test-package` exports `IOS_SIMULATOR_DESTINATION=platform=iOS
    Simulator,OS=…,id=<UDID>` (see select-ios-simulator-destination.py), which names
    the exact device. Fastlane-driven app jobs resolve their destination inside the
    app repos, so no UDID reaches this script and recovery degrades to a bare retry.
    """
    destination = os.environ.get("IOS_SIMULATOR_DESTINATION", "")
    for field in destination.split(","):
        field = field.strip()
        if field.startswith("id="):
            udid = field[len("id="):]
            if udid:
                return udid
    return None


def simctl_devices():
    """Return the known simulator devices as a name→udid and udid→info pair."""
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "--json"],
            capture_output=True,
            text=True,
            check=True,
        )
        data = json.loads(result.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as e:
        print(f"Could not list simulator devices: {e}")
        return {}
    devices = {}
    # `simctl` identifies a device's runtime by the key of the array holding it, not by
    # a field on the record, so the runtime is copied onto each device. Recreation
    # needs it to rebuild the device with `simctl create`.
    for runtime_id, runtime_devices in data.get("devices", {}).items():
        for device in runtime_devices:
            udid = device.get("udid", "")
            if udid:
                device_info = dict(device)
                device_info["runtimeIdentifier"] = runtime_id
                devices[udid] = device_info
    return devices


def recoverable_ci_device(udid):
    """Return the device info for `udid` if recovery may touch it, else None."""
    if not udid:
        return None
    devices = simctl_devices()
    device = devices.get(udid)
    if device is None:
        print(f"Simulator {udid} is not a known device; refusing device-scoped recovery.")
        return None
    name = device.get("name", "")
    if name.startswith(TICKET_DEVICE_PREFIX):
        # PL-376 ownership contract: ticket simulators are never CI-recoverable.
        print(
            f"Refusing to recover simulator {name!r}: 'Ticket'-prefixed devices belong "
            "to agent work, not to CI."
        )
        return None
    return device


def run_simctl(*arguments):
    """Run one `xcrun simctl` command, reporting rather than raising failure."""
    status, _output = run_simctl_with_output(*arguments)
    return status


def run_simctl_with_output(*arguments):
    """Run one `xcrun simctl` command and return `(status, stdout)`."""
    command = ["xcrun", "simctl", *arguments]
    print(f"Executing: {' '.join(command)}")
    try:
        result = subprocess.run(command, capture_output=True, text=True)
    except OSError as e:
        print(f"simctl {' '.join(arguments)} could not run: {e}")
        return 1, ""
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        print(f"simctl {' '.join(arguments)} failed with status {result.returncode}: {detail}")
    return result.returncode, result.stdout


def erase_ci_device(udid):
    """Shut down and erase the single CI-owned simulator `udid`. Returns success."""
    device = recoverable_ci_device(udid)
    if device is None:
        return False
    print(f"Recovering CI simulator {device.get('name', udid)} ({udid}) by shutting it down and erasing it")
    run_simctl("shutdown", udid)  # A shutdown failure must not skip the erase.
    return run_simctl("erase", udid) == 0


def recreate_ci_device(udid):
    """Delete and recreate the single CI-owned simulator `udid`.

    Returns the recreated device's new UDID on success. Returns False when the device
    was deleted but could not be recreated - the caller must then refuse the retry,
    since the destination no longer names an existing device. Returns None when the
    device was left untouched and a plain retry remains reasonable. The new UDID
    differs from `udid` by construction, so the caller must retarget the destination
    before the retry runs.
    """
    device = recoverable_ci_device(udid)
    if device is None:
        return None
    name = device.get("name", "")
    device_type = device.get("deviceTypeIdentifier", "")
    runtime = device.get("runtimeIdentifier", "")
    if not name or not device_type or not runtime:
        print(f"Simulator {udid} lacks the metadata needed for a device-scoped recreate; skipping recovery.")
        return None
    print(f"Recreating CI simulator {name!r} ({udid}) from scratch")
    if run_simctl("shutdown", udid) != 0:
        print("Continuing with deletion despite the shutdown failure")
    if run_simctl("delete", udid) != 0:
        print(f"Could not delete simulator {udid}; leaving it in place")
        return None
    status, output = run_simctl_with_output("create", name, device_type, runtime)
    if status != 0:
        print(f"Deleted simulator {udid} but could not recreate {name!r}")
        return False
    created_udid = output.strip()
    print(f"Recreated simulator {name!r} as {created_udid}")
    return created_udid


def set_destination_udid(udid):
    """Point `IOS_SIMULATOR_DESTINATION` at `udid` for the retry and later steps.

    The retry steps re-read the destination from the environment, so both the running
    process's environment and `$GITHUB_ENV` must name the recreated device; otherwise
    xcodebuild would target the UDID that was just deleted.
    """
    destination = os.environ.get("IOS_SIMULATOR_DESTINATION", "")
    fields = []
    replaced = False
    for field in destination.split(","):
        if field.strip().startswith("id="):
            fields.append(f"id={udid}")
            replaced = True
        else:
            fields.append(field)
    if not replaced:
        print("IOS_SIMULATOR_DESTINATION does not name a device; leaving it unchanged")
        return
    updated = ",".join(fields)
    os.environ["IOS_SIMULATOR_DESTINATION"] = updated
    env_file_path = os.getenv("GITHUB_ENV")
    if env_file_path:
        with open(env_file_path, "a", encoding="utf-8") as f:
            f.write(f"IOS_SIMULATOR_DESTINATION={updated}\n")
    print(f"Retargeted IOS_SIMULATOR_DESTINATION at the recreated simulator: {updated}")


def regenerate_project_without_binary_cache():
    """Regenerate through the repository entry point, with a Tuist fallback."""
    if os.path.isfile("generate.sh") and os.access("generate.sh", os.X_OK):
        print("Regenerating through generate.sh without using the binary cache")
        return os.system("./generate.sh --no-binary-cache")

    if os.path.isfile("Tuist.swift"):
        print("Reinstalling Tuist dependencies and regenerating without warming the binary cache")
        return os.system("tuist install && tuist generate --no-open")

    return 0


def set_retry_after_project_regeneration():
    """Offer a retry only when project regeneration completed successfully."""
    regeneration_status = regenerate_project_without_binary_cache()
    if regeneration_status != 0:
        print(
            f"Project regeneration failed with status {regeneration_status}; "
            "refusing to schedule a retry."
        )
        sys.exit(1)
    set_retry_build()


def handle_derived_data_and_tuist_cache_error(err):
    """Clear stale workspace-local build state and regenerate without warming the binary cache.

    The global Tuist binary cache at `~/.cache/tuist` is shared by every process on the
    machine, so suspect binary-cache state is bypassed via `--no-binary-cache` instead
    of deleted (PL-377).
    """
    print(f"Found linker error requiring derived data and Tuist state clearing: {err}")
    os.system(f"{os.path.dirname(__file__)}/clear-xcode-derived-data.sh")
    project_tuist_path = "Tuist/.build"
    cache_marker_path = os.path.join(project_tuist_path, ".package-resolved-hash")
    if os.path.exists(project_tuist_path):
        print(f"Clearing project-local Tuist dependency state at {project_tuist_path}")
        os.system(f"rm -rf {project_tuist_path}")
    if os.path.exists(cache_marker_path):
        print(f"Clearing project-local Tuist dependency-state marker at {cache_marker_path}")
        os.system(f"rm -f {cache_marker_path}")
    set_retry_after_project_regeneration()


def handle_derived_data_error(err):
    """Handle derived data errors by clearing Xcode derived data"""
    print(f"Found error that requires cleaning derived data: {err}")
    os.system(f"{os.path.dirname(__file__)}/clear-xcode-derived-data.sh")
    set_retry_build()


def handle_simulator_error(err):
    """Recover a simulator error by erasing only the CI-owned simulator device."""
    print(f"Found simulator error: {err}")
    udid = destination_udid()
    if udid is None:
        print(
            "No CI simulator UDID is known (IOS_SIMULATOR_DESTINATION does not name a device), "
            "so no device-scoped recovery is possible. Machine-wide simulator recovery is not "
            "permitted on the shared Studio; retrying without destructive recovery."
        )
    elif erase_ci_device(udid):
        print(f"Erased CI simulator {udid}")
    else:
        print(f"Could not erase CI simulator {udid}; retrying without destructive recovery.")
    set_retry_build()


def handle_recreate_simulators_error(err):
    """Recover a corrupt simulator by erasing, or recreating, only the CI-owned device.

    The corrupt install database behind these errors used to be answered by deleting
    the entire `~/Library/Developer/CoreSimulator` directory. On the shared Studio that
    would destroy every CI and ticket-owned simulator, so the same escalation happens
    one device at a time: erase first, and only if the erase cannot make the device
    usable, delete and recreate that exact device from its own metadata.
    """
    print(f"Found simulator error requiring device recreate: {err}")
    udid = destination_udid()
    if udid is None:
        print(
            "No CI simulator UDID is known (IOS_SIMULATOR_DESTINATION does not name a device), "
            "so no device-scoped recovery is possible. Machine-wide simulator recovery is not "
            "permitted on the shared Studio; retrying without destructive recovery."
        )
    elif erase_ci_device(udid):
        print(f"Erased CI simulator {udid}")
    else:
        recreated_udid = recreate_ci_device(udid)
        if recreated_udid:
            # `simctl create` mints a new UDID, so the retry must target the recreated
            # device rather than the one just deleted.
            set_destination_udid(recreated_udid)
        elif recreated_udid is False:
            # The device was deleted but not recreated, so the destination names
            # nothing that exists; a retry would only repeat the failure.
            print(
                f"CI simulator {udid} was deleted but could not be recreated; "
                "refusing to retry because the destination no longer exists."
            )
            return
        else:
            print(
                f"Could not recover CI simulator {udid} within device-scoped operations; "
                "retrying without destructive recovery."
            )
    set_retry_build()


def handle_tuist_cache_error(err):
    """Clear stale workspace-local Tuist state and regenerate without warming the binary cache.

    Only workspace-owned state is cleared here; the global binary cache is bypassed by
    the `--no-binary-cache` regeneration instead of being deleted for every process on
    the machine (PL-377).
    """
    print(f"Found error that requires clearing Tuist state: {err}")
    project_tuist_path = "Tuist/.build"
    cache_marker_path = os.path.join(project_tuist_path, ".package-resolved-hash")
    if os.path.exists(project_tuist_path):
        print(f"Clearing project-local Tuist dependency state at {project_tuist_path}")
        os.system(f"rm -rf {project_tuist_path}")
    else:
        print(f"Project-local Tuist dependency state not found at {project_tuist_path}")
    if os.path.exists(cache_marker_path):
        print(f"Clearing project-local Tuist dependency-state marker at {cache_marker_path}")
        os.system(f"rm -f {cache_marker_path}")
    set_retry_after_project_regeneration()


def handle_regular_error(err):
    """Handle regular retry errors"""
    print(f"Found build error that requires retry: {err}")
    set_retry_build()


# Ordered highest-priority first; the first category to match wins.
handlers = [
    # Linker errors that require clearing DerivedData and stale Tuist state
    (clear_derived_data_and_tuist_cache_errors, handle_derived_data_and_tuist_cache_error),
    # Errors that require clearing derived data
    (clear_derived_data_errors, handle_derived_data_error),
    # Errors that require recreating simulators from scratch
    (recreate_simulators_errors, handle_recreate_simulators_error),
    # Errors that require a simulator reset
    (simulator_errors, handle_simulator_error),
    # Errors that require clearing stale Tuist state
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
    """Return failures from test plans that did not ultimately pass."""
    failures = []
    for path, name in entries:
        if name.endswith(".xcresult"):
            results = get_test_results(path) or {}
            plans = [node for node in results.get("testNodes", []) if node.get("nodeType") == "Test Plan"]
            if plans and all(node.get("result") == "Passed" for node in plans):
                # A successful retry can leave its earlier failure messages in the bundle.
                print(f"Skipping earlier test failures in {path}: all test plans passed.")
                continue
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
            # The trailing newline is required: GitHub parses the file line by line, and
            # an unterminated line would concatenate with whatever is appended next.
            f.write("RETRY_BUILD=true\n")
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
