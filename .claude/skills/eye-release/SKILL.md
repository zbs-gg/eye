---
name: eye-release
description: Cut a notarized ZBS Eye release — Developer ID build via scripts/build-notarized.sh, notarytool profile setup, stapling verification, and publishing the artifact with gh release create. Use when shipping a build to users.
---

# eye-release — notarized Developer ID release

ZBS Eye ships **outside the App Store** (App Sandbox is incompatible with cross-app AX — the core).
A notarized Developer ID build launches with a double-click, no "Open Anyway", and its signature is
stable: updates never reset the user's Screen Recording/Accessibility permissions. Full background:
`docs/NOTARIZE.md`.

## One-time prerequisites (per machine)

1. Paid Apple Developer Program ($99/yr) — an "Apple Development" cert is NOT enough.
2. A **"Developer ID Application"** certificate in the login keychain
   (Xcode → Settings → Accounts → Manage Certificates → "+"). Verify:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
3. A notarytool keychain profile (app-specific password from appleid.apple.com):
   ```bash
   xcrun notarytool store-credentials zbseye-notary \
     --apple-id <apple-id-email> --team-id <TEAMID> --password <app-specific-password>
   ```
   The script reads the profile name from `ZBSEYE_NOTARY_PROFILE` (default `zbseye-notary`).

No Developer ID yet? The fallback is `scripts/build-release.sh` — self-signed "ZBS Eye Dev": users
install via "Open Anyway", and rebuilds can churn TCC permissions (exactly what notarization removes).

## Build + notarize

```bash
bash scripts/build-notarized.sh
```

The script is self-checking, in order: finds the Developer ID identity → verifies the notarytool
profile BEFORE the long build → `xcodegen generate` → Release build with Hardened Runtime +
`--timestamp --options runtime` → bundles the e5 embedding model (offline first run) → re-signs the
top bundle → `notarytool submit --wait` (2–10 min) → `stapler staple` → Gatekeeper check.

Success looks like:

- `spctl` line contains `accepted` and `source=Notarized Developer ID`
- output artifact: `dist/ZBSEye-notarized-YYYYMMDD.zip` (the stapled app — passes Gatekeeper offline)

If notarytool rejects: `xcrun notarytool log <submission-id> --keychain-profile zbseye-notary` —
usual causes are nested code without Hardened Runtime/timestamp or a stray `get-task-allow`
entitlement from a Debug build (the script builds Release, so normally it passes first try).

## Publish

```bash
VERSION=vX.Y.Z   # match CFBundleShortVersionString
gh release create "$VERSION" dist/ZBSEye-notarized-*.zip \
  --title "ZBS Eye $VERSION" \
  --notes "$(sed -n '/## \[Unreleased\]/,/^## /p' CHANGELOG.md | head -60)"
```

Release notes come from `CHANGELOG.md` — move the `[Unreleased]` items under a version heading in the
same PR that tags the release.

## Post-release sanity

- Download the asset from the GitHub release page (not your local copy) and verify:
  ```bash
  spctl -a -vvv -t exec "/path/to/unzipped/ZBS Eye.app"   # accepted, Notarized Developer ID
  ```
- Install = unzip into `/Applications`, double-click. Permissions are granted once and survive
  future updates (stable signature).
