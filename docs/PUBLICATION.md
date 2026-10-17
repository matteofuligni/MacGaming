# Source publication review — 17 October 2026

## Prepared scope

The publication candidate is an explicit allowlist of source, tests, original icon
drawing, configuration examples, license texts/notices and public documentation.
It uses GPL-3.0-or-later for MacGaming's original work and retains the Steam helper's
original MIT notice. Voluntary funding is documented but no recipient is configured.
See [the license review](LICENSING.md) for the exact external-dependency limitations.

No GitHub repository or public release has been created by these preparation tools.
The public candidate contains no `.git` directory and must start a fresh history.
Do not add a remote to the private development repository and push its existing refs.

## Every committed file was inventoried

All refs and reflogs of the private development repository were enumerated: **2
commits, 57 distinct paths and 75 unique file blobs**. Every historical blob was
read and scanned, rather than checking only the latest working tree. The complete
per-path inventory is [committed-files-audit.json](committed-files-audit.json).
Matched identity/credential values and original author emails are not copied into it.

Findings included historical local paths, a development-layout fallback, device
test records and personal commit identities. Two account-shaped strings in tests
were synthetic redaction fixtures. No high-confidence live credential pattern was
found by the bounded scan. Free text cannot be certified secret-free by pattern
matching alone, so private logs, histories and trial notes are excluded wholesale.

The historical binary asset is a generated `.icns` with PNG EXIF chunks. It is
excluded rather than copying opaque metadata. The original drawing source remains.

## Changes made for portability and privacy

- Storage discovery no longer guesses the original developer's directory layout.
  A standalone copy needs that user's registration or an explicit data root.
- The optional memory-guard script uses its checkout, an explicit argument or the
  data-root environment variable. It no longer scans a fixed development hierarchy.
- Unit tests generate their own volume identity and copy public examples into an
  isolated temporary workspace. They do not read the developer's live profiles,
  storage registration, Steam account or installed runtime.
- Public profile examples include settings only. Checks start pending/untested;
  no personal hardware string, observed game build, date, trial note, save inventory,
  private patch reference or deferred personal experiment selection is exported.
- Runtime examples keep public release provenance and hashes, while disabling
  local HUD logging and omitting acquisition timestamps and local status narratives.
- Public setup documentation uses paths relative to the checkout and explains
  the remaining external-volume/runtime requirements.
- Source metadata and original upstream notices are retained, with a project
  contributor label instead of a private maintainer name or email.

Live game profiles, local registrations, games, prefixes, saves, runtime installs,
logs and backups remain private. Original development files and Git history were
backed up locally before changes; that backup is not part of the publication.

## Reproduce the checked source export

`docs/publication-files.json` is the reviewed allowlist. Adding a file to the
development repository does not automatically add it to this export.

```sh
python3 source/tools/publication.py check
python3 -m unittest discover -s source/tools/publication-tests
python3 source/tools/publication.py audit-history --output logs/private-history-audit.json
python3 source/tools/publication.py export --output exports/open-source/MacGaming
```

The output folder must not exist. The exporter refuses private data roots, path
traversal, input symlinks, non-text payloads and selected secret/identity patterns.
It copies file bytes and normalized permissions only: no Git objects, ACLs, Finder
metadata, extended attributes or source timestamps. It then rejects any unexpected
file in the new candidate. Error reports identify categories and lines, not matched
secret values. These are targeted checks with documented limits, not a formal audit
of every possible secret format.

Before doing any builds or local initialization inside a new candidate, validate it:

```sh
python3 source/tools/publication.py check --root exports/open-source/MacGaming --strict
```

After builds or initialization, the same folder contains ignored generated/private
data. Create a fresh allowlisted export when sharing source again; do not zip the
entire working directory. Strict mode deliberately rejects even `.git` and build
output, while the normal check validates the allowlist only.

## Verification and next decision

The local verification checks Swift unit tests and compilation, Python export/
initialization tests, shell syntax, JSON parsing and privacy checks. A clean source
copy is built in a newly named folder without the private registration or runtimes;
its test summary is reported in the handoff. Optional binary integration tests
are expected to skip, and this does not establish gameplay compatibility.

Next steps are to review the prepared source copy, choose a public repository
owner/name and a public commit identity (a pseudonym/noreply email is possible),
then publish a new initial commit containing only that copy. Activating a funding
provider and distributing executable packages are separate later decisions.
