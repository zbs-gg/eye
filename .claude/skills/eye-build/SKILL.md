---
name: eye-build
description: Build ZBS Eye from a fresh clone or after changes — xcodegen + xcodebuild — and diagnose the common build failures (missing xcodeproj, new files not picked up, scheme name, SPM signing, noise warnings). Use whenever a build is needed or fails.
---

# eye-build — build ZBS Eye and fix the usual breakage

## The happy path

```bash
# 0. Toolchain (once per machine)
xcode-select -p                    # must point at a full Xcode (…/Xcode.app/Contents/Developer), not bare CLT
command -v xcodegen || brew install xcodegen

# 1. Generate the project — ALWAYS. ZBSEye.xcodeproj is NOT in git.
xcodegen generate

# 2. Build (Release compile-check; judged by grep, the log is noisy)
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Release \
  -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"
```

Green = the output ends with `BUILD SUCCEEDED` and there is no `error:` line.
Alternative one-shot gate: `bash scripts/verify.sh` (xcodegen → Debug, ad-hoc Manual signing).

**Never launch the built app.** Launching a differently-signed build over the user's installed app
breaks their Screen Recording permission (cdhash-strict TCC). Compile-check only; the user installs
via `scripts/build-release.sh` / `scripts/build-notarized.sh`.

## Common-failure playbook

| Symptom | Cause → fix |
|---|---|
| `ZBSEye.xcodeproj` does not exist / xcodebuild can't find the project | It's generated, not tracked. Run `xcodegen generate`. |
| `Cannot find 'SomeNewType' in scope` right after you added a new `.swift` file | The project was generated before the file existed (`project.yml` globs `ZBSEyeApp/`). Re-run `xcodegen generate`. |
| `xcodebuild: error: The workspace/scheme ... does not exist` | The scheme is `ZBSEye` (the internal codename), NOT `ZBS Eye` (the brand). Same for the target. |
| Signing errors from SPM dependencies (GRDB, swift-crypto, transformers): "requires a development team" | Automatic signing needs an Apple team. Pass `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""` (the `scripts/verify.sh` pattern) for ad-hoc builds. |
| `CoreSimulator ... version mismatch` warning | Noise. Ignore it; it never fails the build. |
| `xcodegen: command not found` | `brew install xcodegen`. |
| Old build products confuse "did it really build?" | `rm -rf build/DerivedData/Build/Products/*/ZBS\ Eye.app` before building, then check the `.app` exists after (what `scripts/verify.sh` does). |
| Git shows a dirty `ZBSEye.xcodeproj/` | It's gitignored; never commit it. If it shows up, your gitignore is broken — do not force-add. |

## After the build

- Adding user-facing strings? They go into `ZBSEyeApp/Resources/Localizable.xcstrings` (EN key + RU
  translation) — see the checklist in `eye-review-loop`.
- Shipping SQL? Validate on a scratch DB first — `eye-db-validate`.
- Done with a change? Run the `eye-review-loop` skill before opening a PR.
