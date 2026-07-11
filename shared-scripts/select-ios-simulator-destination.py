#!/usr/bin/env python3
"""Select an Xcode destination for the latest available iOS simulator runtime.

The script prints a destination string suitable for xcodebuild, for example:
platform=iOS Simulator,OS=26.5,id=328A8F75-2AEC-40B7-92BC-C7C062F1B9E4

Selection order:
1. Newest available iOS runtime containing the preferred simulator name.
2. Newest available iOS runtime containing any iPhone simulator.
3. Newest available iOS runtime containing any simulator device.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Candidate:
    version: tuple[int, ...]
    version_text: str
    name: str
    udid: str
    preference_rank: int


def parse_runtime(runtime_id: str) -> tuple[tuple[int, ...], str] | None:
    # Example: com.apple.CoreSimulator.SimRuntime.iOS-26-5 -> (26, 5), "26.5"
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime_id)
    if not match:
        return None
    parts = tuple(int(part) for part in match.group(1).split("-"))
    return parts, ".".join(str(part) for part in parts)


def load_devices() -> dict[str, Any]:
    proc = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return json.loads(proc.stdout)


def main() -> int:
    preferred_name = sys.argv[1] if len(sys.argv) > 1 else "iPhone 17 Pro"
    data = load_devices()
    candidates: list[Candidate] = []

    for runtime_id, devices in data.get("devices", {}).items():
        parsed = parse_runtime(runtime_id)
        if parsed is None:
            continue
        version, version_text = parsed
        for device in devices:
            if not device.get("isAvailable", True):
                continue
            name = device.get("name", "")
            udid = device.get("udid", "")
            if not name or not udid:
                continue
            if name == preferred_name:
                preference_rank = 0
            elif name.startswith("iPhone"):
                preference_rank = 1
            else:
                preference_rank = 2
            candidates.append(Candidate(version, version_text, name, udid, preference_rank))

    if not candidates:
        print("::error title=No iOS simulator found::No available iOS simulator devices were found", file=sys.stderr)
        return 1

    # Always choose the newest iOS runtime that has at least one available device.
    # Within that runtime, prefer the requested device type, then any iPhone, then any simulator.
    latest_version = max(candidate.version for candidate in candidates)
    latest_runtime_candidates = [candidate for candidate in candidates if candidate.version == latest_version]
    selected = sorted(latest_runtime_candidates, key=lambda item: item.preference_rank)[0]

    print(f"platform=iOS Simulator,OS={selected.version_text},id={selected.udid}")
    print(
        f"Selected iOS simulator destination: {selected.name} ({selected.udid}) on iOS {selected.version_text}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
