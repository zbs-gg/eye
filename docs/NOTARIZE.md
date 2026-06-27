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
timestamp, packages the e5 model, submits to Apple (`notarytool --wait`, ~2–10 min), runs `stapler staple`
and checks `spctl` (it should be `accepted, source=Notarized Developer ID`). The output is `dist/ZBSEye-notarized-*.zip`.

## Install on the recipient's machine
Unzip into `/Applications`, launch with a **double-click** — Gatekeeper passes it without "Open Anyway"
(even offline, thanks to the stapled ticket). Screen Recording / Accessibility / Microphone permissions are
granted once; the signature is stable, rebuilds don't reset them.

## If notarytool rejected it
`xcrun notarytool log <submission-id> --keychain-profile zbseye-notary` — shows what's not signed
(most often: nested code without Hardened Runtime/timestamp, or a stray `get-task-allow` entitlement from Debug).
The script builds Release (without `get-task-allow`) and sets `--options runtime --timestamp` on the build, so
it usually passes on the first try.

## Current state (before the program)
- The cert right now: only self-signed "ZBS Eye Dev" + "Apple Development". Notarization is blocked until steps 1–2.
- Until there's a program — `scripts/build-release.sh` (self-signed, install via "Open Anyway"). The downsides
  of self-signing (cdhash/TCC churn on every rebuild) are exactly what notarization removes.
