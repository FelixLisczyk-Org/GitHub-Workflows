#!/usr/bin/env python3
"""
Covers the guards that keep `check-build-errors.py` from synchronously warming the Tuist
binary cache or rerunning a full lane for a failure a retry cannot fix:

* the analysis is scoped to the logs of the current invocation (`log_scope`),
* "no such file or directory" only matches a real compiler/linker diagnostic,
* a genuine test failure suppresses the retry entirely.

Run directly: `python3 shared-scripts/tests/test-check-build-errors.py`
"""

import importlib.util
import json
import os
import sys
import tempfile
import time

SHARED_SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, SHARED_SCRIPTS)


def load_check_build_errors():
    """Import the hyphenated script as a module."""
    spec = importlib.util.spec_from_file_location(
        "check_build_errors", os.path.join(SHARED_SCRIPTS, "check-build-errors.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cbe = load_check_build_errors()

FAILURES = []
CHECKS = 0


def check(condition, description):
    global CHECKS
    CHECKS += 1
    if not condition:
        FAILURES.append(description)
        print(f"not ok - {description}")
    else:
        print(f"ok - {description}")


# Real diagnostics: the missing path always follows a colon.
LINKER_ERROR = (
    "ld: warning: Could not find or use auto-linked framework\n"
    "error: no such file or directory: "
    "'/Users/felix/Library/Developer/Xcode/DerivedData/SnipNotes-abc/Build/Products/"
    "Debug-iphonesimulator/cmark_gfm.framework/cmark_gfm'"
)
CLANG_ERROR = "clang: error: no such file or directory: 'Sources/Foo.swift'"

# Benign OS chatter that xctest writes into the same build log. Before the pattern was
# tightened these made a passing platform's log trigger the recovery path.
OS_NOISE = (
    "2026-08-14 09:09:11.702414+0200 xctest[69816:55704763] [logging-persist] "
    "os_unix.c:51044: (2) open(/private/var/db/DetachedSignatures) - No such file or directory\n"
    "2026-08-14 09:09:12.942845+0200 xctest[69816:55704435] [cloudthumbnails.client] "
    "getattrlist() failed for file:///var/folders/wj/T/FileInsertionCoordinatorTests-5E9B - "
    "No such file or directory\n"
    "2026-08-14 09:18:18.399288+0200 xctest[78795:55766098] fopen failed for data file: "
    "errno = 2 (No such file or directory)\n"
)


def test_pattern_precision():
    """A missing build input is matched; the OS chatter around it is not."""
    for text, label in [(LINKER_ERROR, "ld"), (CLANG_ERROR, "clang")]:
        _, handler = cbe.find_handler(text)
        check(
            handler is cbe.handle_derived_data_and_tuist_cache_error,
            f"{label} 'no such file or directory:' diagnostic still triggers cache clearing",
        )

    _, handler = cbe.find_handler(OS_NOISE)
    check(handler is None, "benign xctest 'No such file or directory' chatter no longer matches")

    # A real diagnostic buried in noise must still win.
    _, handler = cbe.find_handler(OS_NOISE + "\n" + LINKER_ERROR + "\n" + OS_NOISE)
    check(
        handler is cbe.handle_derived_data_and_tuist_cache_error,
        "a real diagnostic surrounded by chatter is still matched",
    )


def test_unrelated_patterns_still_match():
    """Adding regex support must not change how the plain string patterns behave."""
    cases = [
        ("ld: symbol(s) not found for architecture arm64", cbe.handle_derived_data_and_tuist_cache_error),
        ("Module compiled with Swift 6.2 cannot be imported by the Swift 6.1.2 compiler", cbe.handle_derived_data_error),
        ("Placeholder did not exist", cbe.handle_recreate_simulators_error),
        ("Failed to establish communication with the test runner", cbe.handle_simulator_error),
        ("Failed to load the test bundle", cbe.handle_tuist_cache_error),
        ("The Xcode build system has crashed", cbe.handle_regular_error),
        ("MyFeatureTests.swift:12: XCTAssertEqual failed", None),
    ]
    for text, expected in cases:
        _, handler = cbe.find_handler(text)
        check(handler is expected, f"{text[:52]!r} maps to {getattr(expected, '__name__', None)}")


def recovery_outcome(handler, generate_script=None, with_tuist_manifest=False, failing_command=None):
    """Run a recovery handler with shell commands captured instead of executed."""
    root = tempfile.mkdtemp()
    if generate_script is not None:
        generate_path = os.path.join(root, "generate.sh")
        with open(generate_path, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/bash\n")
        os.chmod(generate_path, 0o755 if generate_script == "executable" else 0o644)
    if with_tuist_manifest:
        with open(os.path.join(root, "Tuist.swift"), "w", encoding="utf-8") as handle:
            handle.write("// fixture\n")

    commands = []
    retried = False
    exit_code = None
    original_system = cbe.os.system
    original_set_retry = getattr(cbe, "set_retry_build")
    original_cwd = os.getcwd()

    def fake_system(command):
        commands.append(command)
        return 1 if command == failing_command else 0

    def fake_set_retry_build():
        nonlocal retried
        retried = True

    cbe.os.system = fake_system
    setattr(cbe, "set_retry_build", fake_set_retry_build)
    try:
        os.chdir(root)
        try:
            handler("fixture error")
        except SystemExit as error:
            exit_code = error.code
    finally:
        os.chdir(original_cwd)
        cbe.os.system = original_system
        setattr(cbe, "set_retry_build", original_set_retry)
    return commands, retried, exit_code


def test_recovery_regenerates_without_warming_binary_cache():
    """Recovery prefers generate.sh, falls back to Tuist, and never warms binaries."""
    cases = [
        (
            cbe.handle_derived_data_and_tuist_cache_error,
            "executable",
            True,
            "./generate.sh --no-binary-cache",
            "derived-data recovery prefers executable generate.sh",
        ),
        (
            cbe.handle_tuist_cache_error,
            "non-executable",
            True,
            "tuist install && tuist generate --no-open",
            "Tuist-state recovery falls back when generate.sh is not executable",
        ),
        (
            cbe.handle_tuist_cache_error,
            None,
            False,
            None,
            "recovery does nothing when no supported project entry point exists",
        ),
    ]
    for handler, generate_script, with_manifest, expected_command, label in cases:
        commands, retried, exit_code = recovery_outcome(handler, generate_script, with_manifest)
        if expected_command is None:
            check(
                not any(command.startswith(("./generate.sh", "tuist install")) for command in commands),
                label,
            )
        else:
            check(expected_command in commands, label)
        check(
            all("tuist cache" not in command for command in commands),
            f"{label}; no synchronous Tuist binary-cache warm",
        )
        check(retried is True, f"{label}; successful regeneration schedules a retry")
        check(exit_code is None, f"{label}; successful regeneration does not fail analysis")


def test_failed_regeneration_refuses_retry():
    """A failed authoritative or fallback generation aborts instead of retrying."""
    cases = [
        (
            cbe.handle_derived_data_and_tuist_cache_error,
            "executable",
            True,
            "./generate.sh --no-binary-cache",
            "generate.sh failure",
        ),
        (
            cbe.handle_tuist_cache_error,
            "non-executable",
            True,
            "tuist install && tuist generate --no-open",
            "Tuist fallback failure",
        ),
    ]
    for handler, generate_script, with_manifest, failing_command, label in cases:
        commands, retried, exit_code = recovery_outcome(
            handler,
            generate_script,
            with_manifest,
            failing_command,
        )
        check(failing_command in commands, f"{label} is observed by the recovery handler")
        check(retried is False, f"{label} does not set RETRY_BUILD")
        check(exit_code == 1, f"{label} fails the analysis step")


# Real `xcrun simctl list devices --json` schema: the runtime identifies a device by
# the key of the array holding it, and the record itself carries no runtimeIdentifier.
# Recovery must derive that field itself, so the fixture must not pre-enrich it.
RUNTIME_ID = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
CI_SIMULATOR = {
    "name": "iPhone 17 Pro",
    "udid": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    "state": "Booted",
    "isAvailable": True,
}
TICKET_SIMULATOR = dict(CI_SIMULATOR, name="Ticket SX-622 - iPhone 17 Pro")
DESTINATION = f"platform=iOS Simulator,OS=26.5,id={CI_SIMULATOR['udid']}"

# Operations that would mutate state shared by every process on the Studio. No recovery
# path may issue any of them again (PL-377).
MACHINE_GLOBAL_MARKS = (
    "killall",
    "osascript",
    "quit app",
    "CoreSimulatorService",
    "DTServiceHub",
    "Library/Developer/CoreSimulator",
    "Library/Xcode/CoreSimulator",
    ".cache/tuist",
    "org.swift.swiftpm",
)


def simctl_list_json(devices):
    """The simctl JSON for one runtime holding `devices`, exactly as simctl prints it."""
    return {"devices": {RUNTIME_ID: devices}}


class FakeCompleted:
    """Just enough of subprocess.CompletedProcess for the simctl fakes."""

    def __init__(self, returncode, stdout, stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def simulator_outcome(handler, destination=DESTINATION, devices=None, failing_simctl=(), github_env=None):
    """Run a simulator recovery handler with simctl captured instead of executed.

    The subprocess fake returns real-schema simctl JSON for `list` so the handler's
    runtime attribution runs for real, and records every other simctl invocation.
    """
    devices = [CI_SIMULATOR] if devices is None else devices
    simctl_commands = []
    retried = False
    env_at_retry = None
    original_env = os.environ.get("IOS_SIMULATOR_DESTINATION")
    original_github_env = os.environ.get("GITHUB_ENV")
    original_run = cbe.subprocess.run
    original_set_retry = cbe.set_retry_build
    original_system = cbe.os.system
    if destination is None:
        os.environ.pop("IOS_SIMULATOR_DESTINATION", None)
    else:
        os.environ["IOS_SIMULATOR_DESTINATION"] = destination
    if github_env is not None:
        os.environ["GITHUB_ENV"] = github_env

    def fake_run(command, **_kwargs):
        if command[:2] == ["xcrun", "simctl"] and command[2] == "list":
            return FakeCompleted(0, json.dumps(simctl_list_json(devices)))
        simctl_commands.append(tuple(command[2:]))
        verb = command[2]
        stdout = "NEW-UDID\n" if verb == "create" else ""
        return FakeCompleted(1 if verb in failing_simctl else 0, stdout)

    def fake_set_retry_build():
        nonlocal retried, env_at_retry
        retried = True
        env_at_retry = os.environ.get("IOS_SIMULATOR_DESTINATION")
        if github_env is not None:
            # With a $GITHUB_ENV fixture the real writer must run so the test asserts
            # the exact bytes both it and the destination retargeting append.
            original_set_retry()

    cbe.subprocess.run = fake_run
    cbe.set_retry_build = fake_set_retry_build
    cbe.os.system = lambda *_args, **_kwargs: 0
    try:
        try:
            handler("fixture error")
        except SystemExit as error:
            check(error.code == 0, f"{handler.__name__} exits successfully after scheduling the retry")
    finally:
        if original_env is None:
            os.environ.pop("IOS_SIMULATOR_DESTINATION", None)
        else:
            os.environ["IOS_SIMULATOR_DESTINATION"] = original_env
        if original_github_env is None:
            os.environ.pop("GITHUB_ENV", None)
        else:
            os.environ["GITHUB_ENV"] = original_github_env
        cbe.subprocess.run = original_run
        cbe.set_retry_build = original_set_retry
        cbe.os.system = original_system
    return simctl_commands, retried, env_at_retry


def simctl_verbs(commands):
    """The first argument of every captured simctl invocation."""
    return [arguments[0] for arguments in commands]


def test_simulator_recovery_is_device_scoped():
    """A simulator error erases only the CI-owned device from the destination."""
    commands, retried, _env = simulator_outcome(cbe.handle_simulator_error)
    check(
        simctl_verbs(commands) == ["shutdown", "erase"],
        "simulator recovery shuts down and erases exactly the destination device",
    )
    check(
        all(CI_SIMULATOR["udid"] in arguments for arguments in commands),
        "every recovery command names the failed job's own simulator UDID",
    )
    check(retried is True, "device-scoped erase still schedules the retry")


def test_simulator_recovery_refuses_ticket_devices():
    """A `Ticket`-prefixed device is never erased, deleted, or recreated (PL-376)."""
    for handler in (cbe.handle_simulator_error, cbe.handle_recreate_simulators_error):
        commands, retried, _env = simulator_outcome(handler, devices=[TICKET_SIMULATOR])
        check(
            commands == [],
            f"{handler.__name__} runs no commands against a ticket-owned simulator",
        )
        check(retried is True, f"{handler.__name__} still offers the non-destructive retry")


def test_simulator_recovery_without_udid_is_plain_retry():
    """Without a destination UDID the retry is offered without any destructive command."""
    for handler in (cbe.handle_simulator_error, cbe.handle_recreate_simulators_error):
        commands, retried, _env = simulator_outcome(handler, destination=None)
        check(commands == [], f"{handler.__name__} runs nothing when no CI device is known")
        check(retried is True, f"{handler.__name__} still retries without destructive recovery")


def test_recreate_recovery_escalates_to_device_recreate():
    """A failed erase of a corrupt device is answered by recreating that one device."""
    commands, retried, _env = simulator_outcome(
        cbe.handle_recreate_simulators_error, failing_simctl=("erase",)
    )
    verbs = simctl_verbs(commands)
    check(
        verbs == ["shutdown", "erase", "shutdown", "delete", "create"],
        f"a failed erase escalates to delete and recreate, got {verbs}",
    )
    check(
        any(
            arguments[0] == "create"
            and arguments[1:] == (
                CI_SIMULATOR["name"],
                CI_SIMULATOR["deviceTypeIdentifier"],
                # The runtime must be attributed from the enclosing simctl key, not
                # from the device record, which does not carry it.
                RUNTIME_ID,
            )
            for arguments in commands
        ),
        "the recreated device keeps its own name, device type, and runtime",
    )
    check(retried is True, "device-scoped recreate still schedules the retry")


def test_recreate_recovery_retargets_the_destination():
    """The retry must target the recreated device's new UDID, not the deleted one."""
    github_env = os.path.join(tempfile.mkdtemp(), "github_env")
    _commands, retried, env_at_retry = simulator_outcome(
        cbe.handle_recreate_simulators_error,
        failing_simctl=("erase",),
        github_env=github_env,
    )
    retargeted = "platform=iOS Simulator,OS=26.5,id=NEW-UDID"
    check(
        env_at_retry == retargeted,
        "the destination names the recreated device by the time the retry is scheduled",
    )
    with open(github_env, encoding="utf-8") as handle:
        written = handle.read()
    check(
        written == f"IOS_SIMULATOR_DESTINATION={retargeted}\nRETRY_BUILD=true\n",
        "$GITHUB_ENV receives the retargeted destination and the retry flag as two lines",
    )
    check(retried is True, "recreation with retargeting still schedules the retry")


def test_failed_recreate_refuses_retry():
    """A device deleted but not recreated leaves no destination to retry against."""
    _commands, retried, _env = simulator_outcome(
        cbe.handle_recreate_simulators_error,
        failing_simctl=("erase", "create"),
    )
    check(
        retried is False,
        "a delete-without-recreate does not schedule a retry against the missing device",
    )


def test_no_machine_global_recovery_commands():
    """No recovery path may issue an operation that mutates machine-global state."""
    handlers = [
        cbe.handle_derived_data_and_tuist_cache_error,
        cbe.handle_derived_data_error,
        cbe.handle_recreate_simulators_error,
        cbe.handle_simulator_error,
        cbe.handle_tuist_cache_error,
        cbe.handle_regular_error,
    ]
    for handler in handlers:
        if handler in (cbe.handle_simulator_error, cbe.handle_recreate_simulators_error):
            commands, _retried, _env = simulator_outcome(handler)
            captured = [" ".join(arguments) for arguments in commands]
        else:
            commands, _retried, _exit = recovery_outcome(handler, "executable", True)
            captured = commands
        offending = [
            command for command in captured
            if any(mark in command for mark in MACHINE_GLOBAL_MARKS)
        ]
        check(offending == [], f"{handler.__name__} issues no machine-global command")
        check(
            not any(command.startswith(("rm -rf ~", "rm -rf /Users")) for command in captured),
            f"{handler.__name__} removes nothing under the home directory",
        )


def test_priority_is_global():
    """The pre-existing global priority ordering is preserved."""
    combined = "Simulator device failed to install the application\nPlaceholder did not exist"
    _, handler = cbe.find_handler(combined)
    check(
        handler is cbe.handle_recreate_simulators_error,
        "a later high-priority message still outranks an earlier low-priority one",
    )


def test_frameless_runner_crash_retries():
    """A bare `Crash: xctest` is a runner death, not an attributable test failure.

    xcodebuild reports the process death against whichever test the crashed worker had
    next queued, so the named test is frequently one that passes everywhere else. Without
    this classification the build aborts on a failure a rerun recovers from.
    """
    for text in ["Crash: xctest", "crash: xctest", "Crash: xctest\n", "  Crash: xctest  "]:
        _, handler = cbe.find_handler(text)
        check(handler is cbe.handle_regular_error, f"frameless runner crash {text!r} is retryable")

    # The frame is real evidence about a specific test, so it must keep failing the build.
    framed = "Crash: xctest at specialized static Runner._applyScopingTraits(for:testCase:_:)"
    _, handler = cbe.find_handler(framed)
    check(handler is None, "a runner crash naming a frame is still treated as genuine")

    # A crash of some other process is a different signal and must not be swept in.
    _, handler = cbe.find_handler("Crash: SnipNotesApp")
    check(handler is None, "a non-xctest crash is not classified as retryable")


def test_frameless_runner_crash_survives_prefixes():
    """The anchored pattern must still match the message as the xcresult records it."""
    for prefix in ["", "Message: ", "Failure: "]:
        _, handler = cbe.find_handler(f"{prefix}Crash: xctest")
        check(
            handler is cbe.handle_regular_error,
            f"frameless runner crash with {prefix!r} prefix is retryable",
        )


def test_frameless_runner_crash_is_not_genuine():
    """The genuine-failure gate must let the frameless crash through to its handler."""
    failures = [
        {
            "path": ["PersistenceCoreTests", "MarkdownUserDefaultsPersistenceStrategyTests",
                     "Update non-existent note throws error"],
            "message": "Crash: xctest",
            "device": "My Mac",
        }
    ]
    check(
        cbe.find_genuine_test_failures(failures) == [],
        "a frameless runner crash is not counted as a genuine test failure",
    )

    framed = [
        {
            "path": ["LegacyMigrationCoreTests", "LegacyClipboardPreferenceConverterTests",
                     "a fully malformed top-level payload is reported as an invalid value rather than crashing"],
            "message": "Crash: xctest at specialized static Runner._applyScopingTraits(for:testCase:_:)",
            "device": "My Mac",
        }
    ]
    check(
        len(cbe.find_genuine_test_failures(framed)) == 1,
        "a runner crash naming a frame is still counted as a genuine test failure",
    )


def make_log_dir(entries):
    """Create a temp `log` directory; entries is a list of (name, contents, age_seconds)."""
    root = tempfile.mkdtemp()
    log_dir = os.path.join(root, "log")
    os.makedirs(log_dir)
    now = time.time()
    for name, contents, age in entries:
        path = os.path.join(log_dir, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(contents)
        os.utime(path, (now - age, now - age))
    return root


def run_main(root, scope_epoch, test_failures=None):
    """Run `main()` in `root` and report whether it asked for a retry.

    Handlers are neutered so the destructive recovery commands never run, and the
    xcresult reader is stubbed so the test needs no real bundle.
    """
    recorded = {"retry": False}

    def fake_set_retry_build():
        recorded["retry"] = True
        raise SystemExit(0)

    original_set_retry = cbe.set_retry_build
    original_system = cbe.os.system
    original_get_failures = cbe.get_test_failures
    original_cwd = os.getcwd()
    original_epoch = os.environ.pop(cbe.log_scope.SCOPE_EPOCH_VAR, None) if hasattr(cbe, "log_scope") else None
    original_epoch = os.environ.pop("CI_LOG_SCOPE_EPOCH", original_epoch)

    cbe.set_retry_build = fake_set_retry_build
    cbe.os.system = lambda *_args, **_kwargs: 0
    cbe.get_test_failures = lambda _path: list(test_failures or [])
    if scope_epoch is not None:
        os.environ["CI_LOG_SCOPE_EPOCH"] = str(scope_epoch)

    try:
        os.chdir(root)
        try:
            cbe.main()
        except SystemExit:
            pass
    finally:
        os.chdir(original_cwd)
        cbe.set_retry_build = original_set_retry
        cbe.os.system = original_system
        cbe.get_test_failures = original_get_failures
        os.environ.pop("CI_LOG_SCOPE_EPOCH", None)
        if original_epoch is not None:
            os.environ["CI_LOG_SCOPE_EPOCH"] = original_epoch

    return recorded["retry"]


def test_scoping_ignores_earlier_invocations():
    """A previous platform step's log must not drive this step's recovery."""
    root = make_log_dir(
        [
            ("SnipNotesApp-SnipNotes (macOS).log", LINKER_ERROR, 600),
            ("SnipNotesWatchApp-SnipNotes (Apple Watch).log", "Testing failed:\n", 0),
        ]
    )
    check(
        run_main(root, scope_epoch=time.time() - 60) is False,
        "an older platform's linker error is ignored when the logs are scoped",
    )
    check(
        run_main(root, scope_epoch=None) is True,
        "without a scope epoch the whole directory is still scanned (backward compatible)",
    )


def test_scoping_keeps_current_invocation():
    """The failing invocation's own log is still analysed."""
    root = make_log_dir(
        [
            ("SnipNotesApp-SnipNotes (macOS).log", "all good\n", 600),
            ("SnipNotesWatchApp-SnipNotes (Apple Watch).log", LINKER_ERROR, 0),
        ]
    )
    check(
        run_main(root, scope_epoch=time.time() - 60) is True,
        "the current invocation's linker error still triggers a retry",
    )


def test_genuine_test_failure_suppresses_retry():
    """A failing assertion aborts instead of replaying the lane."""
    root = make_log_dir(
        [
            ("SnipNotes (Apple Watch).xcresult", "", 0),
            ("SnipNotesWatchApp-SnipNotes (Apple Watch).log", LINKER_ERROR, 0),
        ]
    )
    genuine = [
        {
            "path": ["MockDataCoreTests", "SampleDataInitializerTests", "watch sample keeps order"],
            "message": "SampleDataInitializerTests.swift:123: Expectation failed: ...",
            "device": "Apple Watch Series 11",
        }
    ]
    check(
        run_main(root, scope_epoch=time.time() - 60, test_failures=genuine) is False,
        "a genuine test failure suppresses the retry even when a build pattern also matches",
    )


def test_infrastructure_test_failure_still_retries():
    """Failures that are infrastructure must still reach their handler."""
    root = make_log_dir(
        [
            ("SnipNotes (iOS).xcresult", "", 0),
            ("SnipNotesApp-SnipNotes (iOS).log", "Testing failed:\n", 0),
        ]
    )
    infrastructure = [
        {
            "path": ["NoteListFeatureTests", "SomeTests", "example"],
            "message": "Failed to establish communication with the test runner",
            "device": "iPhone Air",
        }
    ]
    check(
        run_main(root, scope_epoch=time.time() - 60, test_failures=infrastructure) is True,
        "a test runner communication failure is still treated as retryable infrastructure",
    )


def test_xcresult_bundle_mtime_uses_children():
    """An `.xcresult` is a directory, so its contents decide whether it is current."""
    import log_scope

    root = tempfile.mkdtemp()
    log_dir = os.path.join(root, "log")
    stale = os.path.join(log_dir, "Stale.xcresult")
    rewritten = os.path.join(log_dir, "Rewritten.xcresult")
    os.makedirs(stale)
    os.makedirs(rewritten)
    now = time.time()

    for bundle in (stale, rewritten):
        with open(os.path.join(bundle, "Info.plist"), "w", encoding="utf-8") as handle:
            handle.write("<plist/>")

    # Both bundle directories look old; only one had its contents rewritten in place.
    os.utime(os.path.join(stale, "Info.plist"), (now - 600, now - 600))
    os.utime(stale, (now - 600, now - 600))
    os.utime(rewritten, (now - 600, now - 600))

    original_epoch = os.environ.get("CI_LOG_SCOPE_EPOCH")
    os.environ["CI_LOG_SCOPE_EPOCH"] = str(now - 60)
    try:
        names = [name for _path, name in log_scope.scoped_log_entries(log_dir)]
    finally:
        os.environ.pop("CI_LOG_SCOPE_EPOCH", None)
        if original_epoch is not None:
            os.environ["CI_LOG_SCOPE_EPOCH"] = original_epoch

    check(names == ["Rewritten.xcresult"], "a bundle rewritten in place is kept, a stale one dropped")


def test_missing_log_directory_is_tolerated():
    """A run that never reached the point of writing logs must not raise."""
    import log_scope

    check(log_scope.scoped_log_entries(os.path.join(tempfile.mkdtemp(), "log")) == [],
          "a missing log directory yields no entries")


def test_malformed_scope_epoch_falls_back():
    """A corrupted marker degrades to scanning everything rather than analysing nothing."""
    import log_scope

    original_epoch = os.environ.get("CI_LOG_SCOPE_EPOCH")
    os.environ["CI_LOG_SCOPE_EPOCH"] = "not-a-number"
    try:
        check(log_scope.get_scope_epoch() is None, "a malformed scope epoch is ignored")
    finally:
        os.environ.pop("CI_LOG_SCOPE_EPOCH", None)
        if original_epoch is not None:
            os.environ["CI_LOG_SCOPE_EPOCH"] = original_epoch


def test_find_genuine_test_failures_classification():
    """The gate classifies per failure message, not per bundle."""
    mixed = [
        {"path": ["A", "B", "c"], "message": "Test crashed with signal kill"},
        {"path": ["A", "B", "d"], "message": "XCTAssertEqual failed: (\"1\") is not equal to (\"2\")"},
    ]
    genuine = cbe.find_genuine_test_failures(mixed)
    check(len(genuine) == 1, "only the unexplained failure counts as genuine")
    check(genuine[0]["path"][-1] == "d", "the assertion failure is the one reported")


def test_non_xcresult_entries_are_not_probed():
    """`.log` files must not be handed to the xcresult reader."""
    probed = []
    cbe_get = cbe.get_test_failures
    cbe.get_test_failures = lambda path: probed.append(path) or []
    try:
        cbe.collect_test_failures([("log/build.log", "build.log"), ("log/R.xcresult", "R.xcresult")])
    finally:
        cbe.get_test_failures = cbe_get
    check(probed == ["log/R.xcresult"], "only xcresult bundles are read for test failures")


test_pattern_precision()
test_unrelated_patterns_still_match()
test_recovery_regenerates_without_warming_binary_cache()
test_failed_regeneration_refuses_retry()
test_simulator_recovery_is_device_scoped()
test_simulator_recovery_refuses_ticket_devices()
test_simulator_recovery_without_udid_is_plain_retry()
test_recreate_recovery_escalates_to_device_recreate()
test_recreate_recovery_retargets_the_destination()
test_failed_recreate_refuses_retry()
test_no_machine_global_recovery_commands()
test_priority_is_global()
test_frameless_runner_crash_retries()
test_frameless_runner_crash_survives_prefixes()
test_frameless_runner_crash_is_not_genuine()
test_scoping_ignores_earlier_invocations()
test_scoping_keeps_current_invocation()
test_genuine_test_failure_suppresses_retry()
test_infrastructure_test_failure_still_retries()
test_xcresult_bundle_mtime_uses_children()
test_missing_log_directory_is_tolerated()
test_malformed_scope_epoch_falls_back()
test_find_genuine_test_failures_classification()
test_non_xcresult_entries_are_not_probed()

print()
if FAILURES:
    print(f"{len(FAILURES)} of {CHECKS} checks failed", file=sys.stderr)
    sys.exit(1)
print(f"all {CHECKS} checks passed")
