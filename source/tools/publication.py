#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fail-closed source export. No uploads, Git writes, history rewriting or game access."""
import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys

MANIFEST = "docs/publication-files.json"
PRIVATE_ROOTS = {".git", "backups", "build", "cache", "downloads", "exports", "logs",
                 "manifests", "prefixes", "profiles", "runtimes", "tests", "tmp", "toolchains"}
TEXT_SUFFIXES = {".swift", ".c", ".h", ".py", ".sh", ".md", ".txt", ".json", ".yml", ".example"}
SECRET_PATTERNS = {
    "private-key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "github-token": r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b",
    "aws-key": r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "credential-url": r"https?://[^/\s:@]+:[^/\s@]+@",
    "steam-account": r"\b7656119[0-9]{10}\b",
    "credential-assignment": r"(?i)\b(?:access_token|refresh_token|password|passwd|api_key|client_secret)\s*[:=]\s*[\"']?[A-Za-z0-9_+/=-]{20,}",
    "user-path": r"/(?:Users|home)/[A-Za-z0-9_.-]+/",
    "home-relative-path": r"~/[A-Za-z0-9_.-]+/",
    "local-device-record": r'"hardware"\s*:\s*"[^"\n]+"',
}


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], stderr=subprocess.PIPE)


def private_markers(root):
    """Compute local markers privately; never store their values in reports."""
    markers = set()
    # A CI service account (GitHub's macOS user is "runner") is not a person, and its name
    # matches ordinary source words such as the Swift type Runner.
    if not os.environ.get("GITHUB_ACTIONS"):
        markers.update({getpass.getuser(), str(Path.home())})
    registration = root / "manifests/storage.json"
    if registration.is_file():
        identity = json.loads(registration.read_text())
        markers.update(identity.get(key, "") for key in ["volumeUUID", "mountPoint", "relativeRoot"])
    if (root / ".git").is_dir():
        try:
            identities = git(root, "log", "--all", "--reflog", "--format=%an%x00%ae%x00%cn%x00%ce").decode()
            markers.update(identities.replace("\n", "\0").split("\0"))
        except subprocess.CalledProcessError:
            pass  # A source export can be prepared before the first Git commit.
    return {value for value in markers if len(value) >= 5 and value not in {"MacGaming contributors"}}


def findings(data, markers=()):
    text = data.decode("utf-8", errors="replace")
    result = []
    for kind, pattern in SECRET_PATTERNS.items():
        for match in re.finditer(pattern, text):
            result.append({"kind": kind, "line": text.count("\n", 0, match.start()) + 1})
    for marker in markers:
        for match in re.finditer(re.escape(marker), text, flags=re.IGNORECASE):
            result.append({"kind": "local-identity", "line": text.count("\n", 0, match.start()) + 1})
    return sorted({(item["kind"], item["line"]) for item in result})


def allowed_files(root):
    document = json.loads((root / MANIFEST).read_text())
    names = document["files"]
    if len(names) != len(set(names)) or MANIFEST not in names:
        raise ValueError("Invalid or duplicate publication manifest entries")
    for name in names:
        if not isinstance(name, str):
            raise ValueError("Publication paths must be strings")
        path = PurePosixPath(name)
        if not name or path.is_absolute() or ".." in path.parts or str(path) != name:
            raise ValueError("Unsafe publication path")
        if path.parts[0] in PRIVATE_ROOTS:
            raise ValueError("Private data is forbidden in the publication manifest")
        if path.suffix.lower() in {".dll", ".exe", ".dmg", ".zip", ".pdf", ".pem", ".p12", ".pyc", ".bundle"}:
            raise ValueError("Binary payload or credential file is forbidden")
        if path.suffix not in TEXT_SUFFIXES and path.name not in {"LICENSE", "COPYRIGHT", ".gitignore"}:
            raise ValueError("Only reviewed source/documentation file types can be published")
    return names


def checked_path(root, name):
    current = root
    for part in PurePosixPath(name).parts:
        current = current / part
        if current.is_symlink():
            raise ValueError(f"Symbolic links are forbidden in publication input: {name}")
    if not current.is_file() or not current.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Missing or unsafe publication input: {name}")
    return current


def check(root, strict=False, markers=()):
    names = allowed_files(root)
    issues = []
    for name in names:
        path = checked_path(root, name)
        data = path.read_bytes()
        try:
            data.decode("utf-8")
            if b"\0" in data:
                raise ValueError("binary input")
        except (UnicodeDecodeError, ValueError):
            issues.append({"file": name, "kind": "binary-source-file"})
        for kind, line in findings(name.encode(), markers):
            issues.append({"file": "[redacted filename]", "kind": kind})
        for kind, line in findings(data, markers):
            issues.append({"file": name, "kind": kind, "line": line})
    if strict:
        for path in root.rglob("*"):
            name = path.relative_to(root).as_posix()
            if path.is_symlink():
                issues.append({"file": name, "kind": "unexpected-symlink"})
            elif path.is_file() and name not in names:
                issues.append({"file": name, "kind": "unexpected-file"})
    if issues:
        # Never echo matching values. A failure must not disclose the secret it detected.
        raise ValueError(json.dumps({"issues": issues}, indent=2))
    return [{"path": name, "sha256": hashlib.sha256((root / name).read_bytes()).hexdigest(),
             "bytes": (root / name).stat().st_size} for name in names]


def export(root, destination):
    root, destination = root.resolve(), destination.absolute()
    markers = private_markers(root)
    inventory = check(root, markers=markers)
    if destination.exists() or destination.is_symlink():
        raise ValueError("Export destination must be new; existing exports are never overwritten")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.parent.resolve() != destination.parent:
        raise ValueError("Export parent must be a canonical path without symbolic links")
    destination.mkdir()
    try:
        for item in inventory:
            source = checked_path(root, item["path"])
            target = destination / item["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            # Copy file bytes only: no xattrs, ACLs, Finder data or original timestamps.
            with target.open("xb") as handle:
                handle.write(source.read_bytes())
            target.chmod(0o755 if source.suffix in {".sh", ".py"} else 0o644)
        return check(destination, strict=True, markers=markers)
    except Exception:
        # This directory was created by this call and contains no pre-existing files.
        shutil.rmtree(destination)
        raise


def audit_history(root):
    commits = git(root, "rev-list", "--all", "--reflog").decode().splitlines()
    names = set(allowed_files(root))
    objects = {}
    path_inventory = {}
    for commit in commits:
        for record in git(root, "ls-tree", "-rz", "--full-tree", commit).split(b"\0"):
            if not record:
                continue
            metadata, raw_name = record.split(b"\t", 1)
            mode, kind, oid = metadata.decode().split()
            name = raw_name.decode()
            path_inventory.setdefault(name, {"path": name, "revisions": 0, "objects": set(),
                "publication": "included-current-version" if name in names else "excluded-private-or-historical"})
            path_inventory[name]["revisions"] += 1
            path_inventory[name]["objects"].add(oid)
            objects.setdefault(oid, {"type": kind, "paths": set()})["paths"].add(name)
    markers = private_markers(root)
    blob_inventory = []
    for oid, item in sorted(objects.items()):
        if item["type"] != "blob":
            continue
        data = git(root, "cat-file", "blob", oid)
        hits = findings(data, markers)
        blob_inventory.append({"object": oid, "paths": sorted(item["paths"]), "bytes": len(data),
            "binary": b"\0" in data, "findings": [{"kind": kind, "line": line} for kind, line in hits]})
    for item in path_inventory.values():
        item["objects"] = sorted(item["objects"])
    return {"scope": "Every file revision in all refs and reflogs; values of identities and secrets are omitted.",
            "commitCount": len(commits), "distinctPaths": len(path_inventory), "uniqueBlobs": len(blob_inventory),
            "historyExported": False, "reason": "Private commit identities and historical local paths must not be published.",
            "files": sorted(path_inventory.values(), key=lambda x: x["path"]), "blobs": blob_inventory}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "export", "audit-history"])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--strict", action="store_true", help="Reject every unlisted file, including Git metadata")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.command == "check":
        inventory = check(root, strict=args.strict, markers=private_markers(root))
        print(f"Checked {len(inventory)} allowlisted source files. Private Git history is not approved for publication.")
    elif args.command == "export":
        if args.output is None:
            parser.error("export requires --output")
        inventory = export(root, args.output)
        print(f"Exported {len(inventory)} checked files. No Git metadata, private data or external binaries were copied.")
    else:
        if args.output is None:
            parser.error("audit-history requires a private --output report path")
        report = audit_history(root)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({key: report[key] for key in ["commitCount", "distinctPaths", "uniqueBlobs", "historyExported"]}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Publication check failed: {error}", file=sys.stderr)
        sys.exit(1)
