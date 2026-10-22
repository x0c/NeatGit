# Releasing NeatGit

Authoritative public route: a Developer ID-signed + notarized local release
built by `scripts/publish-release.sh` on the maintainer Mac. The tag CI
workflow (`.github/workflows/release.yml`) is **validation only**: it builds
the tagged source universal, verifies the universal binary and packages, and
keeps them as login-required workflow artifacts (for a public repo any signed-in
person with access can download them: authentication is access control,
not confidentiality). It never creates, uploads to, or
modifies a public GitHub Release.

## Durable release requirements

R1 — Snapshot before build. The script builds the Monaco frontend, runs
`xcodegen generate`, then commits the generated project together with the
whole workspace (`git add -A`, including other agents' unfinished source)
*before* `xcodebuild` archives. Archive, tag, install image, and GitHub
Release all derive from that commit. It records the built `SOURCE_COMMIT`
fingerprint and aborts if `HEAD` moves or the tree goes dirty afterwards.
It never uses destructive isolation (`git stash`, `git reset --hard`,
`git clean` on tracked source, worktree moves of foreign changes).
A dirty tree is committed, not discarded. The pre-existing tag for the
version is verified **before** the costly build/notarization: an existing
tag must point at the snapshot commit (tags are immutable); otherwise
the script aborts instead of moving it.

R2 — Detached notarization wait. Notarization polls for tens of minutes.
The script re-launches itself detached via Python
`subprocess.Popen(..., start_new_session=True)` (survives coordinator /
terminal exit), never macOS `setsid` (does not exist), never a bare
`nohup ... &` under the caller's session. It prints the log path and child
PID and records the PID in `build/release-logs/publish-latest.pid`.

R3 — Local install needs no notarization. Launchability / local overwrite
install (`ditto` a committed-tree build to `/Applications/NeatGit.app`)
works without waiting for notarization; the coordinator performs the
actual install and launch acceptance. Notarization gates only the *public*
artifacts below. `--local-only` still takes a local source snapshot commit
(it must, per R1) but makes **no remote writes**: no push, no tag push, no
GitHub Release changes.

R4 — Public asset set and draft discipline. A public Release `vX.Y.Z`
must contain exactly the signed set, all from the tagged commit:
`signed + notarized + stapled DMG` (first install),
`Sparkle-signed update ZIP` (built from the stapled app),
`SHA256SUMS.txt` covering both. Only signed artifacts are a public
install path. Before any upload the script queries the tag's Release page:
an existing page must be a draft (`isDraft=true`) or the script stops. An
already-published page is never mutated — the only allowed path is a
strictly read-only already-complete check (exact three-file set, then
downloaded bytes verified), after which the script proceeds directly to
the appcast step. "Exact" means whole-set string comparison of the three
expected basenames as fixed strings: near-name matches and any extra
file fail. The script creates a missing page as a **draft**, uploads the
three files one by one with read-back, asserts the exact set, then
downloads the draft assets (authenticated `gh release download` into a
disposable directory) and compares bytes (`cmp`) plus SHA256 against the
locally verified three — names alone never suffice. Only then does it
publish (`gh release edit --draft=false`). Any failure before that point
dies with the page left as a draft; no failure path publishes. Retrying
from the exact same source is safe: the immutable-tag check (R1)
guarantees the tag still matches, and an existing draft for the tag is
reused. Release notes are bilingual (English first, Simplified Chinese
second) with real newlines; the body is the `CHANGELOG.md` section for the
version, which must exist. `CURRENT_PROJECT_VERSION` must be strictly
greater than the live appcast's `<sparkle:version>` (empty appcast counts
as 0 and is only allowed for the first release).

R5 — Portability and secrets. The script stays runnable under macOS
`/bin/bash` 3.2 (no associative arrays, no `${var,,}`, no `readarray`).
Signing identity, team, and notary key defaults are unchanged; the script
never prints secret values or key file contents (only file paths and
Apple submission IDs).

R6 — Appcast / tag sequencing. Tag points at the built source commit; the
appcast update commit (`chore: 发布 vX.Y.Z 更新清单`) lands on `master`
*after* the tag + signed uploads succeed. If the anonymous re-check still
sees the old `<sparkle:version>` at the raw CDN URL while the repo source
already has the new one, that is CDN lag: wait and re-check only. Never
roll back, re-sign, or re-notarize because of it.

R7 — Build identity. The archive builds universal (`ARCHS="arm64 x86_64"`,
`ONLY_ACTIVE_ARCH=NO`) and the script verifies the universal binary with
`lipo`. Before notarization it asserts the built bundle's
`CFBundleShortVersionString` / `CFBundleVersion` equal the configured
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.

## Routes

```bash
scripts/publish-release.sh --dry-run      # preflight only, no writes
scripts/publish-release.sh --local-only   # detached: local snapshot commit, signed+notarized DMG + ZIP, no remote writes
scripts/publish-release.sh --foreground --dry-run   # foreground preflight (debugging only)
```

Detached launch prints `log path + PID`, e.g.
`build/release-logs/publish-*.log (pid NNNN)`. Follow with `tail -f`.
Helper `scripts/run-detached.py` performs the detach; it is also usable
for other long local jobs.

## What the script does, in order

1. Preflight: Developer ID certificate present, notary `.p8` key + API
   credentials live (`notarytool history` reachable), SemVer
   `MARKETING_VERSION`, positive-integer `CURRENT_PROJECT_VERSION` above
   the committed appcast's build number, `CHANGELOG.md` has a section for
   the version, clean merge/rebase state, single-instance lock (same
   worktree never runs two publishes; the lock's parent dir is created
   only on a real run, never during `--dry-run`).
2. Build Monaco frontend (`npm ci && npm run build`), then `xcodegen
   generate`, then commit-first snapshot (`git add -A` +
   commit when dirty), record `SOURCE_COMMIT`, verify the version tag
   (existing tag must equal `SOURCE_COMMIT`).
3. Universal Release archive + Developer ID export, retaining complete
   compiler and export diagnostics. Xcode signs the nested Sparkle
   components during export; do not manually re-sign the exported app.
   Assert bundle marketing/build numbers, EdDSA key match, and each
   executable's signature, hardened runtime, timestamp and absence of
   `get-task-allow`, following [Sparkle's archive/export guidance](https://sparkle-project.org/documentation/).
4. Notarize app zip → staple → re-zip the **stapled** app for Sparkle →
   `generate_appcast` (EdDSA-signed, embedded bilingual notes, XML +
   signature asserts).
5. Build DMG → notarize → staple → `spctl -a -t install` +
   `stapler validate` + `SHA256SUMS.txt` over DMG + ZIP.
6. Full route only: push branch + tag (tag push retried once), create the
   Release as a **draft** with bilingual CHANGELOG-based notes (an existing
   page must be a draft; a published page is never mutated), upload signed
   files one by one with read-back, assert the exact three-file set,
   download-verify bytes + SHA256, then publish the Release, commit + push
   the appcast, anonymous download + XML + build-number verification
   (raw-CDN-lag tolerant retry).

## Ownership split (no contradictions)

The script performs the mechanical release steps above, including tag,
push, draft creation, uploads, and publishing. The coordinator owns
triggering the run, the local install + launch acceptance, and all
recovery decisions (credential/account states, retry vs abort). The
script never decides product scope and never touches public Releases
outside the R4 draft flow.

## Coordinator handoff

Install only after the source snapshot is committed and the signed export validates. Identify the exact installed process, request native Quit, and verify its exit. Stage a fresh `ditto` copy beside the destination and atomically exchange the complete app bundles; never merge bundles or remove the live app before staging succeeds. Launch `/Applications/NeatGit.app`, verify its version/executable identity, then inspect the changed surface. Preserve preferences and repository state. Follow root `AGENTS.md` §8 for acceptance and failure reporting.

## References

- Apple: [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
  (`notarytool submit`, polling `info`, `stapler staple`, `spctl`).
- Sparkle: [Publishing an update](https://sparkle-project.org/documentation/publishing/)
  (`ditto -c -k --sequesterRsrc --keepParent`, `generate_appcast`,
  EdDSA `edSignature`, machine-readable `sparkle:version`).
- GitHub: [Releases REST API](https://docs.github.com/en/rest/releases),
  [least-privilege GITHUB_TOKEN permissions](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/controlling-permissions-for-github_token)
  (validation workflow uses `contents: read`; `upload-artifact` keeps
  packages as login-required workflow artifacts — for a public repo any
  signed-in person with access can download them, so authentication is
  access control, not confidentiality, see
  [actions/upload-artifact](https://github.com/actions/upload-artifact)).
- Workspace: `~/Codes/_standards/workspace-docs/swift-docs/macos-signing-notarization-distribution.md`
  (route A archive+export, self-checks, no `--deep`, no `setsid`).
