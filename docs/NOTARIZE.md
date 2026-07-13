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
and checks `spctl` (it should be `accepted, source=Notarized Developer ID`). It refuses a dirty worktree,
ambiguous signing identities, or an existing artifact with the same candidate identity. The outputs are:

- `dist/ZBSEye-<version>-<build>-<git-sha>-notarized.zip`
- the matching `.manifest.json` with the source revision, ZIP/executable hashes, Team ID, CDHash,
  designated requirement, Hardened Runtime, and release-critical entitlement results.

The archive deliberately does **not** contain the multi-gigabyte generative model. AI is off until the user
opens **Settings → AI** and either chooses **On this Mac** or connects a cloud/account provider. The app verifies the immutable
manifest before activation and stores the model under the resolved ZBS Eye data root. Partial assets,
credentials, logs, and qualification reports must never appear in the release archive.

## Install on the recipient's machine
Verify the ZIP and executable hashes against the adjacent manifest, then unzip that exact candidate into
`/Applications` and launch with a **double-click** — Gatekeeper passes it without "Open Anyway"
(even offline, thanks to the stapled ticket). Screen Recording / Accessibility / Microphone permissions are
granted once; the signature is stable, rebuilds don't reset them.

## If notarytool rejected it
`xcrun notarytool log <submission-id> --keychain-profile zbseye-notary` — shows what's not signed
(most often: nested code without Hardened Runtime/timestamp, or a stray `get-task-allow` entitlement from Debug).
The script builds Release (without `get-task-allow`) and sets `--options runtime --timestamp` on the build, so
it usually passes on the first try.

## Maintainer release state

The release Mac currently has a Developer ID Application certificate and the `zbseye-notary` keychain
profile. Re-check both before a release; the build script fails before compiling if either is unavailable.
Contributors without those credentials can still use `scripts/build-release.sh` for a self-signed local build,
but that artifact is not a distributable ZBS Eye release and may churn TCC permissions.
