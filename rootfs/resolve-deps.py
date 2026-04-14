#!/usr/bin/env python3
"""Resolve Alpine package filenames and dependencies from APKINDEX files."""

import re
import sys
from collections import defaultdict

REPOS = {
    "main": "/tmp/apkindex-main.txt",
    "community": "/tmp/apkindex-community.txt",
}

TARGETS = ["python3", "gcc", "musl-dev", "make", "lua5.4"]

# Packages already in minirootfs — skip these and anything they provide
BASE_PKGS = {
    "musl", "busybox", "alpine-baselayout", "alpine-keys", "apk-tools",
    "libc-utils", "scanelf", "ca-certificates-bundle", "ssl_client",
    "zlib", "libcrypto3", "libssl3",
}


def parse_index(path):
    """Parse an APKINDEX file into a list of package dicts."""
    pkgs = []
    with open(path) as f:
        text = f.read()
    for block in text.strip().split("\n\n"):
        pkg = {}
        for line in block.splitlines():
            if ":" in line:
                key, _, val = line.partition(":")
                pkg[key] = val
        if "P" in pkg and "V" in pkg:
            pkgs.append(pkg)
    return pkgs


def strip_version_constraint(dep):
    """Remove version operators from a dep string: 'foo>=1.2' -> 'foo'."""
    return re.split(r"[><=~]", dep)[0]


def build_indices(all_pkgs):
    """Build lookup tables:
    - by_name: package_name -> (repo, pkg_dict)
    - by_provides: provided_name -> (repo, pkg_dict)
    """
    by_name = {}
    by_provides = {}
    for repo, pkg in all_pkgs:
        name = pkg["P"]
        # First occurrence wins (main before community)
        if name not in by_name:
            by_name[name] = (repo, pkg)
        # Parse provides field
        if "p" in pkg:
            for token in pkg["p"].split():
                prov = strip_version_constraint(token)
                if prov not in by_provides:
                    by_provides[prov] = (repo, pkg)
    return by_name, by_provides


def resolve(targets, by_name, by_provides, base_pkgs):
    """Recursively resolve all deps, returning {pkg_name: (repo, filename)}."""
    resolved = {}  # pkg_name -> (repo, filename)
    queue = list(targets)
    visited = set()

    while queue:
        dep = queue.pop()
        dep_clean = strip_version_constraint(dep)

        if dep_clean in visited:
            continue
        visited.add(dep_clean)

        # Skip base packages and their known provides
        if dep_clean in base_pkgs:
            continue

        # Skip /bin/sh and similar path deps (provided by busybox)
        if dep_clean.startswith("/"):
            continue

        # Look up the dep: first by name, then by provides (handles so:* deps)
        entry = by_name.get(dep_clean) or by_provides.get(dep_clean)
        if not entry:
            print(f"WARNING: could not resolve dependency: {dep_clean}", file=sys.stderr)
            continue

        repo, pkg = entry
        name = pkg["P"]
        if name in resolved or name in base_pkgs:
            continue

        filename = f"{name}-{pkg['V']}.apk"
        resolved[name] = (repo, filename)

        # Enqueue this package's deps
        if "D" in pkg:
            for d in pkg["D"].split():
                queue.append(d)

    return resolved


def main():
    # Parse both indexes, main first so it takes priority
    all_pkgs = []
    for repo_name, path in REPOS.items():
        for pkg in parse_index(path):
            all_pkgs.append((repo_name, pkg))

    by_name, by_provides = build_indices(all_pkgs)

    # Also register base package provides so we can skip so:* deps they satisfy
    base_provides = set(BASE_PKGS)
    for bpkg_name in list(BASE_PKGS):
        entry = by_name.get(bpkg_name)
        if entry:
            _, pkg = entry
            if "p" in pkg:
                for token in pkg["p"].split():
                    base_provides.add(strip_version_constraint(token))

    resolved = resolve(TARGETS, by_name, by_provides, base_provides)

    # Group by repo
    by_repo = defaultdict(list)
    for name, (repo, filename) in sorted(resolved.items()):
        by_repo[repo].append(filename)

    for repo in ["main", "community"]:
        for fn in sorted(by_repo.get(repo, [])):
            print(f"{repo}:{fn}")

    total = sum(len(v) for v in by_repo.values())
    print(f"\n# Total packages: {total}", file=sys.stderr)


if __name__ == "__main__":
    main()
