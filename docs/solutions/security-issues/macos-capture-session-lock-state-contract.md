---
title: Fail-closed macOS capture gates with the real session dictionary contract
date: 2026-07-26
category: security-issues
module: screen-capture-session-policy
problem_type: security_issue
component: service_object
symptoms:
  - After display wake while the Mac remained locked, ZBS Eye persisted a com.apple.loginwindow frame and lock-screen OCR.
  - The first fail-closed hardening reported capture as active but persisted no frames during an ordinary unlocked session.
  - A valid on-console, login-complete CGSession dictionary omitted CGSSessionScreenIsLocked in the normal unlocked state.
  - A missed unlock notification could leave the cached lock gate closed after the session was already unlocked.
root_cause: wrong_api
resolution_type: code_fix
severity: critical
related_components:
  - testing_framework
  - development_workflow
tags:
  - screen-capture
  - lock-screen
  - privacy-boundary
  - cg-session
  - fail-closed
  - screen-capture-kit
  - release-dogfood
---

# Fail-closed macOS capture gates with the real session dictionary contract

## Problem

macOS lock, screen-saver, display-wake, and unlock notifications are transition hints, not authorization to capture. ZBS Eye must prove at every persistence boundary that the current login session is unlocked and the foreground process is ordinary user content.

The defect appeared in two successive forms. In v0.4.3, a screen-saver stop notification could resume capture while the login session was still locked, and installed-app dogfood persisted a `com.apple.loginwindow` frame with lock-screen OCR. [PR #26](https://github.com/zbs-gg/eye/pull/26) closed that leak, but v0.4.4 then rejected every ordinary unlocked capture because it treated an absent `CGSSessionScreenIsLocked` key as an unknown session. On a normal unlocked Mac, `CGSessionCopyCurrentDictionary()` returned a valid dictionary with `kCGSSessionOnConsoleKey = true` and `kCGSessionLoginDoneKey = true`, but omitted the lock key. [PR #27](https://github.com/zbs-gg/eye/pull/27) corrected the parser without weakening the privacy boundary.

The v0.5.0 candidate exposed a third form: `screenLocked` could become a permanent latch. A missed or early unlock notification left both cached flags closed, the active timer returned before polling the live session, and every wake fallback required the stale cached flag to be open already. The same dogfood pass also found that a Touch ID UI agent could persist AX text because filtering a system shell from Activities is not the same as rejecting it at capture time.

## Symptoms

- After display wake while the Mac was still locked, v0.4.3 inserted a frame whose bundle identifier was `com.apple.loginwindow`.
- In v0.4.4, REST and MCP reported recording as active and frame processing ran, but the database maximum capture ID stayed unchanged because the final admission check rejected every unlocked frame.
- The live unlocked session dictionary was present and marked both on-console and login-complete, yet omitted `CGSSessionScreenIsLocked`. The current parser documents that observed macOS shape (`ZBSEyeApp/Capture/CaptureSessionPolicy.swift`).
- Compilation, unit tests, signing, notarization, `/health`, and a nominal “capturing” state could all pass while the installed product either leaked protected content or stored no useful frames.

## What Didn't Work

### Trusting transition notifications as authorization

The original implementation let a screen-saver stop event clear suspension. That event can arrive before the login session is actually unlocked, so a delayed timer or in-flight capture could cross the privacy boundary. The coordinator now routes system wake, display wake, and screen-saver stop through a fresh session check (`ZBSEyeApp/Capture/CaptureCoordinator.swift`) instead of treating those notifications as proof of unlock.

### Treating a missing lock key as a failed query

Fail-closed behavior was applied at the wrong level. A missing dictionary, malformed values, non-console session, or pre-login session must remain unknown and rejected. An absent lock key inside an otherwise valid on-console, login-complete dictionary is the observed normal unlocked representation. Conflating those shapes made v0.4.4 private but unusable.

### Making the cached lock bit a prerequisite for reconciliation

The first resume policy required both the cached `screenLocked` bit and a fresh session query to say unlocked. That is safe only if the distributed unlock notification is guaranteed, which it is not. Once the cached bit became true, the timer also returned on `suspended` before making another authoritative query, so a missed event could never repair itself.

The opposite shortcut is also wrong: clearing every suspension after any unlocked poll would resume capture during an active non-locking screen saver or display sleep. Session-lock recovery and unrelated display suspension must remain distinct.

### Checking only before asynchronous capture work

A frame can begin while unlocked and finish after a lock notification because accessibility extraction and ScreenCaptureKit processing both suspend across `await` (`ZBSEyeApp/Capture/CaptureCoordinator.swift`). A start-of-cycle guard cannot revoke work already in flight.

### Relying on source shape and release infrastructure

The coordinator tests prove that the final guard appears between frame production and the first write (`ZBSEyeTests/CaptureCoordinatorSessionStateTests.swift`), but a source-ordering test cannot prove that a live CoreGraphics dictionary is interpreted correctly. Compilation, unit tests, signing, notarization, and a healthy control plane also do not prove that the installed app writes ordinary unlocked frames and refuses locked ones.

## Solution

### Normalize the dictionary into a three-state result

`CaptureSessionPolicy.sessionLockState(from:)` returns `true` for definitely locked, `false` for definitely unlocked, and `nil` for unknown. It first requires a current on-console, login-complete session; only then does an absent lock key mean unlocked (`ZBSEyeApp/Capture/CaptureSessionPolicy.swift`):

```swift
static func sessionLockState(from sessionInfo: [String: Any]?) -> Bool? {
    guard let sessionInfo else { return nil }
    guard sessionInfo[macOSOnConsoleKey] as? Bool == true,
          sessionInfo[macOSLoginDoneKey] as? Bool == true else { return nil }
    guard let rawValue = sessionInfo[macOSLockKey] else { return false }
    return rawValue as? Bool
}
```

The policy therefore distinguishes:

- `nil`, empty, malformed, non-console, and pre-login inputs → unknown, rejected fail-closed;
- valid on-console plus login-complete with `CGSSessionScreenIsLocked = true` → locked;
- valid on-console plus login-complete with the lock key false or absent → unlocked.

Executable policy tests cover the observed missing-key shape, explicit true/false values, and failed or malformed inputs (`ZBSEyeTests/CaptureSessionPolicyTests.swift`).

### Reconcile the session before the suspended timer guard

`startupGate` treats `true` and `nil` as closed. `periodicGate` polls before the timer's suspension guard: a definite lock closes the gate, a definite unlock repairs a prior session-lock latch, and an unknown result admits no capture for that tick. An unlocked poll does not clear an unrelated display/screen-saver suspension. Wake, unlock, and screen-saver-stop hints use the same fresh-query policy instead of mutating the cached flags directly.

After a verified session-boundary resume, the coordinator awaits `FramePipeline.invalidateSessionBoundary()`, which clears stale ScreenCaptureKit content and pre-lock dedup hashes. It rechecks the current session after that actor suspension and only then triggers capture. This ordering makes the first ordinary post-unlock frame observable without weakening the final persistence gate.

### Recheck immediately before persistence

After frame processing completes, the coordinator calls `currentSessionStillAllowsCapture()` before either a context-only write or an image write (`ZBSEyeApp/Capture/CaptureCoordinator.swift`). That helper freshly resolves both the foreground bundle and `CGSessionCopyCurrentDictionary()`.

The shared admission policy requires both tracked and current session state to be unlocked, then explicitly denies loginwindow, screen-saver, Touch ID/LocalAuthentication, SecurityAgent, and authorizationhost surfaces. Known protected applications are excluded in the ScreenCaptureKit filter before the screenshot. The pipeline re-attests the protected process set after every suspending capture stage; if it changed, the in-flight result and content cache are discarded before OCR or persistence. Read boundaries also hide legacy protected rows from Timeline, Search, Ask, REST/MCP, summaries, statistics, achievements, and export without deleting the user's database or media. Tests cover lock and unknown-state revocation, stale-lock repair, preservation of unrelated suspension, protected-surface rejection, legacy direct-ID/search/Ask access, aggregates, and media export.

### Qualify the installed notarized artifact

The installed notarized v0.4.5 artifact was exercised against the live database and actual system lock screen:

- ordinary unlocked capture advanced the database maximum capture ID;
- while locked, the maximum stayed unchanged for at least 45 seconds;
- after unlock, capture resumed and the first new frame was Finder;
- zero new `loginwindow` or screen-saver frames appeared;
- a system screenshot completed in 0.19 seconds while Eye was recording;
- the prior recording intent was restored after dogfood.

This gate verifies both halves of the contract: privacy while locked and liveness after unlock.

## Why This Works

The policy is fail-closed about uncertainty without confusing uncertainty with macOS's legitimate unlocked representation. `nil` means “not proven safe,” while a missing lock key means unlocked only after the dictionary has proven that it describes the active on-console, login-complete session.

The coordinator then uses three independent defenses:

1. Notification-driven state suspends immediately, while periodic reconciliation can repair a stale session latch without clearing an unrelated display suspension.
2. Protected authentication and lock applications are excluded in ScreenCaptureKit and rejected before AX/SCK work when foreground.
3. A final fresh session-and-bundle check revokes an in-flight frame immediately before any write.

The protected-shell denylist remains a last defense if notification ordering or tracked state is stale (`ZBSEyeApp/Capture/CaptureSessionPolicy.swift`).

## Prevention

- Treat lock, wake, screen-saver, and unlock notifications as triggers to re-evaluate state, never as the state authority.
- Preserve the three-state contract in executable tests. Add fixtures for every live macOS dictionary shape observed in the field, especially the valid unlocked dictionary with no lock key, while keeping malformed, non-console, and pre-login inputs fail-closed.
- Keep the final admission check after the last asynchronous frame-producing operation and before every persistence path.
- Keep protected system shells explicitly denied even when other session checks appear sufficient.
- Qualify releases with unit tests plus real installed-app dogfood: use the cycle heartbeat or SCK logs for liveness because dedup can legitimately keep the database maximum unchanged; then prove the verified session-boundary reset writes a fresh ordinary post-unlock row and zero protected-surface rows.
- Treat a failed public artifact as immutable history: stop recording, withdraw the release and tag, restore the last known-good app, advance version/build, and repeat the full gate. Never replace bytes under an existing public version.
- Restore the user's prior recording intent after dogfood, whether the gate passes or fails.

## Related Issues

- [PR #23 — suspend capture when launched under lock screen](https://github.com/zbs-gg/eye/pull/23): earlier protection for launch-while-locked.
- [PR #26 — fix lock-screen capture privacy boundary](https://github.com/zbs-gg/eye/pull/26): added wake-safe resume, the final pre-write gate, and protected-shell rejection.
- [PR #27 — fix unlocked capture after privacy hardening](https://github.com/zbs-gg/eye/pull/27): accepted the observed unlocked dictionary only when it is on-console and login-complete.
- [ZBS Eye v0.4.5](https://github.com/zbs-gg/eye/releases/tag/v0.4.5): published resolution artifact; v0.4.3 and v0.4.4 were withdrawn during installed-app dogfood.
