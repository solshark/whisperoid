#!/usr/bin/env python3
"""Generates Resources/THIRD-PARTY-NOTICES.txt from the resolved dependencies.

Both MIT and Apache 2.0 require their notices to be preserved in binary
redistribution, so this file has to travel inside the .app rather than only
living in the repository. Generating it from the actual checkouts means it
cannot drift out of date when a dependency is added, removed or upgraded.

Apache 2.0 section 4(d) additionally requires the contents of any NOTICE file
to be reproduced, so those are included where present.

Run after `swift package resolve`:

    python3 scripts/make-notices.py
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECKOUTS = ROOT / ".build" / "checkouts"
OUTPUT = ROOT / "Resources" / "THIRD-PARTY-NOTICES.txt"


def resolved_packages():
    data = json.loads((ROOT / "Package.resolved").read_text())
    pins = data.get("pins") or data.get("object", {}).get("pins", [])
    packages = []
    for pin in pins:
        identity = pin.get("identity") or pin.get("package", "")
        location = pin.get("location") or pin.get("repositoryURL", "")
        state = pin.get("state") or {}
        version = state.get("version") or (state.get("revision") or "")[:8]
        packages.append((identity, version, location))
    return sorted(packages)


def checkout_for(identity):
    """Checkout directory names do not always match the package identity."""
    for candidate in sorted(CHECKOUTS.iterdir()):
        if candidate.is_dir() and candidate.name.lower() == identity.lower():
            return candidate
    for candidate in sorted(CHECKOUTS.iterdir()):
        if candidate.is_dir() and identity.lower() in candidate.name.lower():
            return candidate
    return None


def read_named(directory, prefix):
    for entry in sorted(directory.iterdir()):
        if entry.is_file() and entry.name.lower().startswith(prefix):
            return entry.read_text(encoding="utf-8", errors="replace").strip()
    return None


def licence_kind(text):
    if not text:
        return "UNKNOWN"
    head = text[:400].lower()
    if "apache license" in head:
        return "Apache-2.0"
    if "mit license" in head or "permission is hereby granted, free of charge" in head:
        return "MIT"
    if re.search(r"bsd|redistribution and use in source", head):
        return "BSD"
    return "UNKNOWN"


def main():
    if not CHECKOUTS.is_dir():
        sys.exit("error: .build/checkouts missing; run `swift package resolve` first")

    packages = resolved_packages()
    components = []
    apache_text = None

    for identity, version, location in packages:
        directory = checkout_for(identity)
        if directory is None:
            sys.exit(f"error: no checkout found for {identity}")

        licence = read_named(directory, "licen")
        kind = licence_kind(licence)
        if kind == "Apache-2.0" and apache_text is None:
            apache_text = licence

        components.append({
            "name": directory.name,
            "version": version,
            "url": location.removesuffix(".git"),
            "kind": kind,
            "licence": licence,
            "notice": read_named(directory, "notice"),
        })

    unknown = [c["name"] for c in components if c["kind"] == "UNKNOWN"]
    if unknown:
        sys.exit(f"error: could not classify licences for: {', '.join(unknown)}")

    out = []
    out.append("Whisperoid — third-party notices")
    out.append("")
    out.append("Whisperoid incorporates the following open source components.")
    out.append("Each remains under its own licence and the notices below are")
    out.append("reproduced as those licences require. Whisperoid itself is")
    out.append("distributed under the MIT License; see LICENSE.")
    out.append("")
    out.append("=" * 72)
    out.append("COMPONENTS")
    out.append("=" * 72)
    out.append("")
    for c in components:
        out.append(f"{c['name']} {c['version']}")
        out.append(f"    {c['url']}")
        out.append(f"    {c['kind']}")
        out.append("")

    # MIT carries its copyright inside the licence text, so each MIT component
    # is reproduced in full. Apache 2.0 is identical for every component, so it
    # appears once, with the per-component NOTICE files listed separately.
    for c in components:
        if c["kind"] == "MIT" and c["licence"]:
            out.append("=" * 72)
            out.append(f"{c['name']} — MIT License")
            out.append("=" * 72)
            out.append("")
            out.append(c["licence"])
            out.append("")

    notices = [c for c in components if c["notice"]]
    if notices:
        out.append("=" * 72)
        out.append("NOTICE FILES (Apache License 2.0, section 4(d))")
        out.append("=" * 72)
        out.append("")
        for c in notices:
            out.append(f"--- {c['name']} ---")
            out.append("")
            out.append(c["notice"])
            out.append("")

    apache_components = [c["name"] for c in components if c["kind"] == "Apache-2.0"]
    if apache_text:
        out.append("=" * 72)
        out.append("Apache License 2.0")
        out.append("=" * 72)
        out.append("")
        out.append("Applies to: " + ", ".join(apache_components))
        out.append("")
        out.append(apache_text)
        out.append("")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(out) + "\n", encoding="utf-8")

    print(f"wrote {OUTPUT.relative_to(ROOT)}")
    for c in components:
        marker = " +NOTICE" if c["notice"] else ""
        print(f"  {c['name']:<24} {c['kind']}{marker}")


if __name__ == "__main__":
    main()
