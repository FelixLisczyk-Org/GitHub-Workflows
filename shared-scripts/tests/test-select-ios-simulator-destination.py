#!/usr/bin/env python3
"""
Covers the PL-376 ownership contract in `select-ios-simulator-destination.py`:
CI must never select a `Ticket <ID> - ...` simulator, not even as the any-iPhone
fallback when no regular simulator matches on the newest runtime. Agent work keeps
installed app and data state on those devices, and a CI job sharing one would both
flake and clobber that state.

Run directly: `python3 shared-scripts/tests/test-select-ios-simulator-destination.py`
"""

import contextlib
import importlib.util
import io
import os
import sys

SHARED_SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, SHARED_SCRIPTS)


def load_destination_selector():
    """Import the hyphenated script as a module."""
    spec = importlib.util.spec_from_file_location(
        "select_ios_simulator_destination",
        os.path.join(SHARED_SCRIPTS, "select-ios-simulator-destination.py"),
    )
    module = importlib.util.module_from_spec(spec)
    # The dataclass decorator resolves the module during class creation, so the
    # module must be registered before it executes.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


selector = load_destination_selector()

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


def device(name, udid):
    return {"name": name, "udid": udid, "isAvailable": True}


def run_selection(devices_by_runtime, preferred):
    """Run `main()` against fixture devices and return (exit_code, printed destination)."""
    selector.load_devices = lambda: {"devices": devices_by_runtime}
    original_argv = sys.argv
    sys.argv = ["select-ios-simulator-destination.py", preferred]
    captured = io.StringIO()
    try:
        with contextlib.redirect_stdout(captured):
            code = selector.main()
    finally:
        sys.argv = original_argv
    return code, captured.getvalue().strip()


TICKET_UDID = "TICKET-UDID-0001"
REGULAR_UDID = "REGULAR-UDID-0001"

# The ticket simulator sits on the newest runtime; only an older runtime offers a
# regular device. CI must take the older runtime's regular device regardless.
code, destination = run_selection(
    {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            device("Ticket SX-622 - iPhone 17 Pro", TICKET_UDID)
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
            device("iPhone Air", REGULAR_UDID)
        ],
    },
    "iPhone 17 Pro",
)
check(code == 0, "a selection is still made when only older runtimes have regular devices")
check(
    TICKET_UDID not in destination,
    "a ticket-owned simulator is never selected, not even as the newest-runtime fallback",
)
check(REGULAR_UDID in destination, "the regular simulator on the older runtime is selected")

# If every matching device is ticket-owned there is nothing CI may use: the selection
# must fail with the existing error rather than reach for an agent-owned device.
code, destination = run_selection(
    {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            device("Ticket SX-622 - iPhone 17 Pro", TICKET_UDID)
        ],
    },
    "iPhone 17 Pro",
)
check(code == 1, "an all-ticket device pool fails the selection instead of sharing an agent simulator")

print()
if FAILURES:
    print(f"{len(FAILURES)} of {CHECKS} checks failed", file=sys.stderr)
    sys.exit(1)
print(f"all {CHECKS} checks passed")
