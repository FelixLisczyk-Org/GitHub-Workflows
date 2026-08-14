"""
Scopes the `log` directory to the artifacts produced by the current build/test
invocation.

Every platform step in a job shares one `log` directory: Fastlane's scan writes
`log/<Product>-<Scheme>.log` and `log/<Scheme>.xcresult` per invocation, and nothing
clears it in between (`prepare-xcode-build` only wipes it once per job). Analysing the
whole directory therefore lets a *passing* platform's log drive another platform's
failure recovery - a benign `[cloudthumbnails.client] getattrlist() failed ... No such
file or directory` line written by the macOS and iOS steps made the watchOS step clear
its Tuist cache and rerun the lane twice against a genuine test failure.

The composite actions export CI_LOG_SCOPE_EPOCH (a float Unix timestamp) immediately
before each invocation, so every entry modified at or after it belongs to that
invocation. When the variable is absent the whole directory is scanned, keeping older
callers of these scripts working unchanged.
"""

import os

LOG_DIR = "log"
SCOPE_EPOCH_VAR = "CI_LOG_SCOPE_EPOCH"


def get_scope_epoch():
    """Return the current invocation's scope timestamp, or None when unscoped."""
    raw = os.getenv(SCOPE_EPOCH_VAR, "").strip()
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        print(f"Warning: ignoring malformed {SCOPE_EPOCH_VAR}={raw!r}; scanning all of {LOG_DIR}/")
        return None


def entry_mtime(path):
    """Latest modification time of a log entry.

    `.xcresult` bundles are directories, and a directory's own mtime only tracks entries
    being added or removed directly inside it, so the immediate children are considered
    too rather than risk discarding a bundle that was rewritten in place.
    """
    mtimes = [os.path.getmtime(path)]
    if os.path.isdir(path):
        for child in os.scandir(path):
            mtimes.append(child.stat().st_mtime)
    return max(mtimes)


def scoped_log_entries(log_dir=LOG_DIR):
    """Return `(path, name)` for the log entries produced by the current invocation.

    Returns an empty list when the directory does not exist; callers own the messaging
    for that case because it means different things to each of them.
    """
    if not os.path.isdir(log_dir):
        return []

    scope_epoch = get_scope_epoch()
    entries = []
    skipped = []
    for name in sorted(os.listdir(log_dir)):
        path = os.path.join(log_dir, name)
        if scope_epoch is not None:
            try:
                if entry_mtime(path) < scope_epoch:
                    skipped.append(name)
                    continue
            except OSError as error:
                print(f"Warning: could not read the modification time of {path}: {error}")
                continue
        entries.append((path, name))

    if skipped:
        print(f"Ignoring {len(skipped)} log entries from earlier invocations: {', '.join(skipped)}")
    return entries
