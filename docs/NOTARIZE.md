# Notarizing ZBS Eye (Developer ID, distribution outside the App Store)

> **Why not the App Store.** The App Store requires App Sandbox, under which cross-app Accessibility is
> impossible (reading the AX tree of other apps — the main path of text extraction), plus an "eternal memory,
> records everything" profile is almost guaranteed to be rejected on privacy. All the equivalents (Rewind
> before Apple, screenpipe) are distributed via **Developer ID + notarization**. This both keeps the features
> and removes the cdhash/"Open Anyway"/TCC churn of self-signing (a notarized signature is stable — permissions survive rebuilds).

## One-time setup

### 1. The paid Apple Developer Program — $99/year
- https://developer.apple.com/programs/enroll/ → Enroll (as Individual). Pay $99; activation is usually within a day.
- Your current **"Apple Development"** certificate is **NOT suitable** for notarization — that type is for
  running on your own devices. You need a **"Developer ID Application"** (it only appears in the paid program).

### 2. The "Developer ID Application" certificate
Easiest via Xcode:
- Xcode → **Settings → Accounts** → select the Apple ID → **Manage Certificates…** → **"+"** →
  **Developer ID Application**. The cert lands in the login keychain.
- Check: `security find-identity -v -p codesigning | grep "Developer ID Application"` — there should be a line.

(Alternative: developer.apple.com → Certificates → "+" → Developer ID Application → upload a CSR from
Keychain Access → Certificate Assistant.)

### 3. App-specific password for notarytool
- https://appleid.apple.com → **Sign-In and Security → App-Specific Passwords** → **"+"** → name it
  "zbseye-notary" → copy a password like `abcd-efgh-ijkl-mnop`.

### 4. Store the notarytool credentials in the keychain (once)
```bash
xcrun notarytool store-credentials zbseye-notary \
  --apple-id YOUR_APPLE_ID_EMAIL \
  --team-id YOUR_TEAM_ID \
  --password ABCD-EFGH-IJKL-MNOP        # that same app-specific one
```
`TEAM_ID` is the 10-character code from developer.apple.com → Membership (or from the cert name in
parentheses: `Developer ID Application: Name (ABCDE12345)`).

## Build + notarize (every release)

```bash
bash scripts/build-notarized.sh
```
The script does it all: builds Release with **Hardened Runtime**, signs with **Developer ID** + a secure
timestamp, packages the e5 retrieval model, submits to Apple (`notarytool --wait`, ~2–10 min), runs `stapler staple`
and checks `spctl` (it should be `accepted, source=Notarized Developer ID`). Before `xcodegen` or archive work,
`scripts/release-preflight.sh` fails closed unless all of the following are true:

- the worktree has no staged, unstaged, or nonignored untracked files;
- no tracked file is hidden by `assume-unchanged`/`skip-worktree`, and no ignored file exists inside a
  recursively compiled shipping source root;
- `origin` is the canonical `zbs-gg/eye` GitHub SSH/HTTPS repository;
- a fresh fetch of `origin/main` and tags succeeds, and candidate `HEAD` exactly equals that fetched main;
- the app and test targets agree on version/build, the version is newer than the latest strict `vX.Y.Z`
  release tag, the build number is greater than that release's build, and the candidate tag does not exist.

Pre-release tags such as `v0.4.3-beta.1` and other `v`-prefixed names are intentionally excluded from the
release baseline. Immediately before publishing a prepared release, re-run the full release identity gate with
`bash scripts/release-preflight.sh --verify-only`; it freshly fetches canonical main again and requires exact
equality. The test-only fixture hook is guarded by `ZBSEYE_RELEASE_PREFLIGHT_FIXTURE=1` and is never used by
the notarized build.

The build also refuses ambiguous signing identities or an existing artifact with the same candidate identity.
Its final two `✅` lines print the exact release paths. Copy those complete paths; never discover an asset with
a wildcard, a timestamp sort, or "newest file". The public outputs are one exact pair:

- `dist/ZBSEye-<version>-<build>-<12-character-source>-notarized.zip`
- `dist/ZBSEye-<version>-<build>-<12-character-source>-notarized.manifest.json`, with the source revision,
  ZIP/executable hashes, Team ID, CDHash,
  designated requirement, Hardened Runtime, release-critical entitlement results, Apple notarization status,
  submission ID, and the SHA-256 digest of Apple's notarization log.

Treat the locally generated manifest as the qualified candidate identity. Before upload, publication, or
installation, assign `ZIP` and `MANIFEST` by pasting the two exact paths printed by the build, then verify both
the manifest-bound hashes and the independently pinned Developer ID publisher without globbing:

```bash
ZIP='paste the exact dist/...-notarized.zip path printed by the build'
MANIFEST='paste the exact dist/...-notarized.manifest.json path printed by the build'
bash scripts/verify-release-artifact.sh "$ZIP" "$MANIFEST"
```

Attach exactly `$ZIP` and `$MANIFEST` to the draft GitHub release. After downloading those two named assets
into a clean directory, compare the downloaded manifest byte-for-byte with the qualified local manifest and
verify the downloaded app's real publisher identity before publishing:

```bash
QUALIFIED_MANIFEST="$MANIFEST"
DOWNLOADED_ZIP='paste the exact downloaded ZIP path'
DOWNLOADED_MANIFEST='paste the exact downloaded manifest path'
bash scripts/verify-release-artifact.sh "$DOWNLOADED_ZIP" "$DOWNLOADED_MANIFEST" "$QUALIFIED_MANIFEST"
```

Install that exact verified draft download into `/Applications`, preserving the previous installed bundle as
a rollback without changing the data root, media, models, preferences, Keychain, or TCC grants. Then run the
installed-app privacy and liveness gate before publishing:

1. Record the live database maximum capture ID and the user's current recording setting.
2. Enable recording through the installed app's real MCP surface. Activate an ordinary app and require the
   database maximum to advance; a healthy control plane with no new row is a failure.
3. Lock the Mac using the normal system lock/screen-saver path. Leave it locked for several capture intervals
   and require the database maximum to stay unchanged.
4. Unlock normally, activate an ordinary app, and require the database maximum to advance again. The first
   post-unlock row must be ordinary user content, and the whole test window must contain zero `loginwindow`
   or screen-saver rows.
5. Take a normal system screenshot while Eye records and confirm it completes promptly without a new
   permission prompt.
6. Restore the user's original recording setting and stop the temporary MCP client, even when a check fails.

The session-state contract and exact failure modes are documented in
[`docs/solutions/security-issues/macos-capture-session-lock-state-contract.md`](solutions/security-issues/macos-capture-session-lock-state-contract.md).
If the draft fails any step, delete the draft, restore the last known-good installed app, fix the defect, and
advance both version and build before rebuilding. Do not publish a failed candidate or replace bytes under an
existing version.

Re-run `bash scripts/release-preflight.sh --verify-only` immediately before the public transition. After
publishing, verify that GitHub reports the expected size and SHA-256 digest for both public assets; a public
artifact is immutable release history. If post-public verification ever fails, withdraw the release and tag,
restore the last known-good app, and ship the correction under a higher version/build.

The raw `notarytool submit` JSON and Apple log are retained outside the repository and `dist/`, by default under
`~/Library/Application Support/ZBS Eye Maintainer/Release Evidence/`. The script prints the exact directory,
uses directory mode `700` and file mode `600`, and never writes credentials there. Set
`ZBSEYE_RELEASE_EVIDENCE_DIR` to another private durable location if needed. Keep this evidence private; the
public manifest binds the accepted status, submission ID, and log digest without exposing a local filesystem path.

The archive deliberately does **not** contain the multi-gigabyte generative model. AI is off until the user
opens **Settings → AI** and either chooses **On this Mac** or connects a cloud/account provider. The app verifies the immutable
manifest before activation and stores the model under the resolved ZBS Eye data root. Partial assets,
credentials, logs, and qualification reports must never appear in the release archive.

## Install on the recipient's machine
Use the exact ZIP named by the verified manifest; do not select an artifact by wildcard or recency. Run the
artifact verifier above against the downloaded ZIP, downloaded manifest, and retained qualified manifest,
then unzip that exact candidate into `/Applications`
and launch with a **double-click** — Gatekeeper passes it without "Open Anyway"
(even offline, thanks to the stapled ticket). Screen Recording / Accessibility / Microphone permissions are
granted once; the signature is stable, rebuilds don't reset them.

## If notarytool rejected it
The build script retrieves and retains Apple's log even for an accepted submission. For an older/manual submission,
`xcrun notarytool log <submission-id> --keychain-profile zbseye-notary` shows what's not signed
(most often: nested code without Hardened Runtime/timestamp, or a stray `get-task-allow` entitlement from Debug).
The script builds Release (without `get-task-allow`) and sets `--options runtime --timestamp` on the build, so
it usually passes on the first try.

## Maintainer release state

The release Mac currently has a Developer ID Application certificate and the `zbseye-notary` keychain
profile. Re-check both before a release; the build script fails before compiling if either is unavailable.
Contributors without those credentials can still use `scripts/build-release.sh` for a self-signed local build,
but that artifact is not a distributable ZBS Eye release and may churn TCC permissions.
