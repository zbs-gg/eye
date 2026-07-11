# Investigation: system audio crackle was not attributable to ZBS Eye

- **Reported:** 2026-07-11
- **Original severity:** High — system-wide audio crackled while ZBS Eye was not running.
- **Area reviewed:** `SystemAudioCaptureEngine`, `AudioCoordinator`, app termination and relocation drains.
- **Status:** Original root-cause claim disproved. Separate normal-exit lifecycle defects were found and hardened.

## Reported symptom

Music and other system audio crackled after ZBS Eye had stopped. The persisted ZBS Eye audio mode was `off`, and no ZBS Eye process was running.

## What live inspection actually showed

The machine exposed an aggregate CoreAudio device with UID `~:AMS2_Aggregate:0`, class `aagg`, and sample rate `0`. More detailed HAL inspection showed:

- no input or output streams;
- no subdevices, taps, or subtaps;
- an empty global CoreAudio tap list;
- the device was neither the default device nor running;
- no owning application or ZBS Eye identifier.

The device was persisted in `/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist` and remained after `coreaudiod` was restarted. Restarting the daemon reduced its resident memory, but did **not** remove this device. Therefore the previous remediation claim — “restart `coreaudiod` and the ZBS Eye orphan disappears” — was false on the affected Mac.

Unified logs also contained the same generic HAL failure path from WebKit and Steam before ZBS Eye encountered it. The log event is not application attribution.

## Verdict on the original hypothesis

There is no evidence that ZBS Eye created this aggregate device. ScreenCaptureKit gives ZBS Eye an `SCStream`; the app does not create a named aggregate device or receive a stable CoreAudio UID that could safely be enumerated and deleted later.

An automatic startup sweep would therefore be dangerous: it could delete persistent audio state belonging to macOS, BlackHole, a DAW, conferencing software, or another user tool. No such sweep should ship without an exact, app-owned identifier and a reproducible attribution chain.

## Real ZBS Eye defects found during the investigation

The original device attribution was wrong, but the capture lifecycle still had real bugs:

1. `SCStream.stopCapture()` was launched fire-and-forget, so Quit and relocation did not wait for the physical system-audio session to stop.
2. A stop racing an asynchronous start could publish a late session after Stop.
3. Sample callbacks read mutable engine state across queues without one synchronized admission boundary.
4. A failed teardown could permanently block a later retry.
5. Quit could continue after an unconfirmed teardown, or a rejected Quit could leave recording suspended.

## Implemented hardening

- one lifecycle owner serializes start, stop, late-start rejection, and restart;
- the exact `SCStream` is retained until `stopCapture()` returns;
- stop failures are typed, retried, and remain retryable on the next Stop/Quit;
- sample delivery uses a locked session-identity admission gate;
- relocation waits without a deadline and fails closed unless physical teardown is confirmed;
- Quit uses a bounded wait, stays open when teardown is unconfirmed, and resumes recording after the rejected Quit;
- normal termination drains system audio before process-provider/model shutdown and backup.

## Verification boundary

Unit tests cover teardown waiting, stop-during-start, retry after failure, timeout ownership, external stop, and stale-frame rejection. Release compilation is also required.

A physical system-audio capture test changes the user's current `off` mode and may touch TCC/audio hardware, so it must be run only with explicit consent. A `SIGKILL` cannot execute app cleanup; no claim of crash recovery should be made until a reproducible, ZBS-Eye-attributed SCK/CoreAudio object can be observed before and after the kill.
