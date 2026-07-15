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

Run only from a clean checkout whose `HEAD` is the freshly fetched canonical `origin/main`.
`scripts/release-preflight.sh` also rejects hidden tracked changes, ignored files inside compiled source
roots, a non-monotonic version/build, an existing candidate tag, and disagreement between app and test
target versions.

The build verifies the Developer ID identity and notary profile before the long work, creates a Hardened
Runtime Release archive, submits it to Apple, staples the accepted ticket, and checks Gatekeeper. It prints
one exact ZIP and one exact manifest whose names include version, build, and source revision:

```text
dist/ZBSEye-<version>-<build>-<12-character-source>-notarized.zip
dist/ZBSEye-<version>-<build>-<12-character-source>-notarized.manifest.json
```

Copy those exact paths from the output. Never rediscover an artifact by wildcard, modification time, or
“newest file”. Verify the pair before upload:

```bash
ZIP='paste exact path printed by the build'
MANIFEST='paste matching exact path printed by the build'
bash scripts/verify-release-artifact.sh "$ZIP" "$MANIFEST"
```

If notarytool rejects: `xcrun notarytool log <submission-id> --keychain-profile zbseye-notary` —
usual causes are nested code without Hardened Runtime/timestamp or a stray `get-task-allow`
entitlement from a Debug build (the script builds Release, so normally it passes first try).

## Draft and reverse-verify

```bash
TAG=vX.Y.Z
SOURCE=$(git rev-parse HEAD)
gh release create "$TAG" "$ZIP" "$MANIFEST" --draft --target "$SOURCE" \
  --title "ZBS Eye $TAG" --notes-file /path/to/release-notes.md
```

Download the two exact named draft assets into a clean directory. Keep the locally generated manifest as
the trust anchor and verify the downloaded bytes against it:

```bash
QUALIFIED_MANIFEST="$MANIFEST"
DOWNLOADED_ZIP='exact downloaded ZIP path'
DOWNLOADED_MANIFEST='exact downloaded manifest path'
bash scripts/verify-release-artifact.sh \
  "$DOWNLOADED_ZIP" "$DOWNLOADED_MANIFEST" "$QUALIFIED_MANIFEST"
```

The draft target must equal `SOURCE`; GitHub's reported asset sizes and SHA-256 digests must match the
qualified local pair.

## Installed-artifact privacy and liveness gate

Install the verified draft ZIP into `/Applications` while preserving the previous installed bundle as a
rollback. Do not change the data root, database, media, models, preferences, Keychain, or TCC grants.

Before publishing, exercise the installed app and live database:

1. Save the current recording setting and database maximum capture ID.
2. Enable recording through the installed app's real MCP surface. Activate an ordinary app and require the
   maximum ID to advance. “Capturing” with no new row fails the gate.
3. Lock the Mac normally. Leave it locked for several capture intervals and require the maximum ID to remain
   unchanged.
4. Unlock normally, activate an ordinary app, and require capture to resume. The first post-unlock row must
   be ordinary user content, with zero `loginwindow` or screen-saver rows in the test window.
5. Take a normal system screenshot while Eye records and confirm prompt-free, responsive completion.
6. Restore the saved recording setting and stop the temporary MCP client, whether the gate passes or fails.

See `docs/solutions/security-issues/macos-capture-session-lock-state-contract.md` for the session contract
and the two failure modes this gate catches. If any step fails, delete the draft, restore the known-good app,
fix the defect, and advance version **and** build before rebuilding.

## Publish and verify public identity

Immediately before publication:

```bash
bash scripts/release-preflight.sh --verify-only
gh release edit "$TAG" --draft=false
```

Confirm the public release is not a draft or prerelease, targets `SOURCE`, and reports the qualified size and
SHA-256 digest for both assets. Re-downloading and running `verify-release-artifact.sh` again is the strongest
check when the network permits.

A public release is immutable history. Never replace bytes under an existing version. If post-public
verification fails, withdraw the release and tag, restore the known-good app, and ship a higher version/build.

## Completion

- Keep the private notarization evidence printed by the build under the maintainer evidence directory.
- Keep the newly installed release only after the complete dogfood gate passes; then old rebuildable archives
  and temporary downloads may be removed.
- Report the exact release URL, version/build/source, test result, installed state, recording state, and any
  remaining manual action.
