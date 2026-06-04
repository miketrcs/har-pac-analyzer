#!/usr/bin/env python3
"""
Generate Sources/RCSPACFileParser/TrackerDatabase.swift from DuckDuckGo Tracker Radar.

Usage (run from repo root):
    python3 Scripts/generate_tracker_db.py

The script clones a shallow sparse copy of tracker-radar to /tmp/tracker-radar,
reads every domain JSON file that carries category data, maps the DDG categories
to our ServiceCategory / AccessCriticality values, and writes the Swift source
file that backs TrackerDatabase.lookup().

Re-run whenever you want to pull a fresh snapshot of the tracker-radar data.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

REPO_URL = "https://github.com/duckduckgo/tracker-radar.git"
CLONE_DIR = Path("/tmp/tracker-radar")
DOMAINS_DIR = CLONE_DIR / "domains" / "US"

# Maps DDG category strings → (ServiceCategory raw value, AccessCriticality raw value).
# First match wins when a domain has multiple categories, so put "required" entries first.
CATEGORY_PRIORITY: list[tuple[str, str, str]] = [
    # Required — these must be bypassed for content to load
    ("Federated Login",             "identity",           "required"),
    ("SSO",                         "identity",           "required"),
    ("Online Payment",              "api",                "required"),
    ("CDN",                         "cdnStatic",          "required"),
    # Optional — safe to send through proxy or allow policy to decide
    # Analytics before pure-ad categories: domains like google-analytics.com carry
    # both labels, but should surface as Analytics rather than Ads in the UI.
    # Pure ad-serving domains (doubleclick.net) only have Ad labels, so they still
    # resolve correctly.
    ("Analytics",                   "analytics",          "optional"),
    ("Third-Party Analytics Marketing", "analytics",      "optional"),
    ("Audience Measurement",        "analytics",          "optional"),
    ("Tag Manager",                 "analytics",          "optional"),
    ("Advertising",                 "ads",                "optional"),
    ("Ad Motivated Tracking",       "ads",                "optional"),
    ("Action Pixels",               "ads",                "optional"),
    ("Ad Fraud",                    "ads",                "optional"),
    ("Session Replay",              "telemetry",          "optional"),
    ("Fraud Prevention",            "telemetry",          "optional"),
    ("Social Network",              "thirdPartySupport",  "optional"),
    ("Social - Share",              "thirdPartySupport",  "optional"),
    ("Social - Comment",            "thirdPartySupport",  "optional"),
    ("Embedded Content",            "thirdPartySupport",  "optional"),
    ("Support Chat Widget",         "thirdPartySupport",  "optional"),
    ("Badge",                       "thirdPartySupport",  "optional"),
    ("Consent Management Platform", "thirdPartySupport",  "optional"),
    # Unknown / skip
    ("Non-Tracking",                "unknown",            "unknown"),
    ("Malware",                     "unknown",            "unknown"),
    ("Unknown High Risk Behavior",  "unknown",            "unknown"),
    ("Obscure Ownership",           "unknown",            "unknown"),
]

PRIORITY_MAP = {cat: (svc, crit) for cat, svc, crit in CATEGORY_PRIORITY}
PRIORITY_ORDER = [cat for cat, _, _ in CATEGORY_PRIORITY]


def clone_or_update() -> None:
    if DOMAINS_DIR.exists():
        print(f"Using existing clone at {CLONE_DIR}")
        return
    print("Cloning tracker-radar (sparse, depth 1)…")
    subprocess.run(
        ["git", "clone", "--filter=blob:none", "--sparse", "--depth", "1", REPO_URL, str(CLONE_DIR)],
        check=True,
    )
    subprocess.run(
        ["git", "sparse-checkout", "set", "domains/US"],
        cwd=CLONE_DIR,
        check=True,
    )
    print("Clone complete.")


def best_category(categories: list[str]) -> tuple[str, str] | None:
    """Return (ServiceCategory raw, AccessCriticality raw) for the highest-priority category."""
    for cat in PRIORITY_ORDER:
        if cat in categories:
            svc, crit = PRIORITY_MAP[cat]
            if svc == "unknown":
                return None  # Don't emit entries that add no information
            return svc, crit
    return None


def build_table() -> dict[str, tuple[str, str]]:
    table: dict[str, tuple[str, str]] = {}
    for fname in os.listdir(DOMAINS_DIR):
        if not fname.endswith(".json"):
            continue
        path = DOMAINS_DIR / fname
        try:
            with open(path) as fh:
                data = json.load(fh)
        except (json.JSONDecodeError, OSError):
            continue

        categories = data.get("categories", [])
        if not categories:
            continue

        result = best_category(categories)
        if result is None:
            continue

        domain = data.get("domain", "")
        if not domain or domain.startswith("*") or domain.startswith("%"):
            continue

        svc, crit = result
        table[domain.lower()] = (svc, crit)

    return table


SWIFT_CATEGORY_CASES = {
    "cdnStatic":          ".cdnStatic",
    "fileStorage":        ".fileStorage",
    "identity":           ".identity",
    "api":                ".api",
    "telemetry":          ".telemetry",
    "analytics":          ".analytics",
    "ads":                ".ads",
    "thirdPartySupport":  ".thirdPartySupport",
    "coreApp":            ".coreApp",
    "unknown":            ".unknown",
}

SWIFT_CRITICALITY_CASES = {
    "required": ".required",
    "optional": ".optional",
    "unknown":  ".unknown",
}


def render_swift(table: dict[str, tuple[str, str]]) -> str:
    lines: list[str] = []
    lines.append("// This file is generated by Scripts/generate_tracker_db.py — do not edit by hand.")
    lines.append("// Re-run that script to update from the latest DuckDuckGo Tracker Radar snapshot.")
    lines.append("// Source: https://github.com/duckduckgo/tracker-radar (Apache 2.0 / CC BY-NC-SA 4.0)")
    lines.append("")
    lines.append("enum TrackerDatabase {")
    lines.append("    /// Look up a host or registrable domain in the tracker-radar snapshot.")
    lines.append("    /// Returns nil when the domain is unknown to the database.")
    lines.append("    static func lookup(_ host: String) -> (ServiceCategory, AccessCriticality)? {")
    lines.append("        domainTable[host]")
    lines.append("    }")
    lines.append("")
    lines.append("    static let domainTable: [String: (ServiceCategory, AccessCriticality)] = [")

    for domain in sorted(table):
        svc_raw, crit_raw = table[domain]
        svc_swift = SWIFT_CATEGORY_CASES[svc_raw]
        crit_swift = SWIFT_CRITICALITY_CASES[crit_raw]
        escaped = domain.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'        "{escaped}": ({svc_swift}, {crit_swift}),')

    lines.append("    ]")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    # Resolve output path relative to this script's location (Scripts/ → project root)
    script_dir = Path(__file__).resolve().parent
    output_path = script_dir.parent / "Sources" / "RCSPACFileParser" / "TrackerDatabase.swift"

    clone_or_update()

    print("Processing domain files…")
    table = build_table()
    print(f"  {len(table)} domains classified.")

    swift_src = render_swift(table)
    output_path.write_text(swift_src, encoding="utf-8")
    print(f"Wrote {output_path}")
    print(f"  Lines: {swift_src.count(chr(10))}")


if __name__ == "__main__":
    main()
