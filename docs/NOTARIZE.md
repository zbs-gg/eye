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
- `origin` is the canonical `zbs-gg/eye` GitHub SSH/HTTPS repository;
- a fresh fetch of `origin/main` and tags succeeds, and candidate `HEAD` exactly equals that fetched main;
- the app and test targets agree on version/build, the version is newer than the latest strict `vX.Y.Z`
  release tag, the build number is greater than that release's build, and the candidate tag does not exist.

Pre-release tags such as `v0.4.3-beta.1` and other `v`-prefixed names are intentionally excluded from the
release baseline. Immediately before publishing a prepared release, re-run the network identity portion with
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

Treat the matching manifest as authoritative. Before upload, publication, or installation, assign `ZIP` and
`MANIFEST` by pasting the two exact paths printed by the build, then verify the pair without globbing:

```bash
ZIP='paste the exact dist/...-notarized.zip path printed by the build'
MANIFEST='paste the exact dist/...-notarized.manifest.json path printed by the build'

test "$(basename "$ZIP")" = "$(/usr/bin/plutil -extract artifact raw -o - "$MANIFEST")"
test "$(/usr/bin/plutil -extract version raw -o - "$MANIFEST")" = '0.4.3'
test "$(/usr/bin/plutil -extract build raw -o - "$MANIFEST")" = '8'
test "$(/usr/bin/plutil -extract sourceRevision raw -o - "$MANIFEST")" = "$(git rev-parse HEAD)"
test "$(shasum -a 256 "$ZIP" | awk '{print $1}')" = \
  "$(/usr/bin/plutil -extract zipSHA256 raw -o - "$MANIFEST")"

VERIFY_DIR="$(mktemp -d)"
ditto -x -k "$ZIP" "$VERIFY_DIR"
test "$(shasum -a 256 "$VERIFY_DIR/ZBS Eye.app/Contents/MacOS/ZBS Eye" | awk '{print $1}')" = \
  "$(/usr/bin/plutil -extract executableSHA256 raw -o - "$MANIFEST")"
rm -rf "$VERIFY_DIR"
```

Attach exactly `$ZIP` and `$MANIFEST` to the draft GitHub release. After downloading those two named assets
into a clean directory, repeat the same checks against the downloaded bytes before publishing. Re-run
`bash scripts/release-preflight.sh --verify-only` immediately before the public transition.

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
Use the exact ZIP named by the verified manifest; do not select an artifact by wildcard or recency. Verify the
downloaded ZIP and unpacked executable hashes as above, then unzip that exact candidate into `/Applications`
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
