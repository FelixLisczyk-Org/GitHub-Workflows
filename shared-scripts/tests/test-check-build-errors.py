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


def test_priority_is_global():
    """The pre-existing global priority ordering is preserved."""
    combined = "Simulator device failed to install the application\nPlaceholder did not exist"
    _, handler = cbe.find_handler(combined)
    check(
        handler is cbe.handle_recreate_simulators_error,
        "a later high-priority message still outranks an earlier low-priority one",
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
test_priority_is_global()
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
