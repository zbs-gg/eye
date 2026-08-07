# Capture coexistence qualification

This gate answers one release question: does the exact installed ZBS Eye candidate make ordinary macOS
screenshots slower, stale, or unavailable while ChatGPT, Chronicle, and a real two-track call compete for
the same macOS capture stack?

It is a release qualification, not a repair tool. It never changes macOS permissions, launches or quits an
app, restarts a daemon, or sends a signal to another process. The operator creates each bracket state. Run it
from Terminal so Eye, ChatGPT, and Chronicle can be genuinely absent during the baseline arms.

## What is measured

The automated bracket is fixed:

1. Baseline A — Eye, ChatGPT, and Chronicle quit.
2. Eye — installed Eye running alone.
3. Baseline B — all three apps quit.
4. ChatGPT + Chronicle — both running, Eye quit.
5. Baseline C — all three apps quit.
6. Eye + Chronicle — both running, ChatGPT quit.
7. Baseline D — all three apps quit.
8. Eye + ChatGPT + Chronicle + real call — a real ChatGPT call is live and Eye shows both microphone and
   system tracks.
9. Baseline E — all three apps quit.

Every arm performs 5 warm-ups and 100 measured main-display `/usr/sbin/screencapture -m` attempts. A uniformly selected
100–900 ms pause precedes every attempt, so the bracket crosses short-lived capture phases instead of creating
an artificial tight loop. Terminal must stay fully visible: its changing attempt marker is the freshness
witness. Each image must be non-empty, decode through `sips`, and have a new normalized-pixel fingerprint;
the disposable image and normalization file are then deleted. The private TSV retains only attempt number,
random delay, latency, and `ok`/`error`/`empty`/`stale`.

The automated fingerprint catches an unchanged returned buffer. It cannot prove that an advancing buffer is
the exact state at the keypress, so keypress-to-content freshness remains a blocking manual shortcut check.

The hard attempt watchdog and absolute maximum are 500 ms. A run passes only with zero errors, empty images,
or stale fingerprints; an attributable nearest-rank p95 increase of at most 50 ms; and each active arm's
maximum no more than 100 ms above the larger adjacent-baseline maximum. Adjacent baseline controls may differ
by at most 50 ms at p95 and 100 ms at maximum; a larger control shift makes the run `invalid` instead of
allowing subtraction to hide it. A slow or broken baseline is always `upstream-blocked`, never a product pass.
In Eye arms, coarse capture health must be `healthy` before and after measurement. The exact PID sets for Eye,
ChatGPT, and the Chronicle main process are recorded before and after every arm and must remain identical;
Chronicle's `--screen-capture-child` alone does not satisfy an arm. Every active Eye arm requires exactly one
GUI PID whose command is the exact installed executable. The health request reads only the regular `port` file
below the canonical `--data-root`, proves through `lsof` that this exact PID owns the listener both before and
after `curl`, and rejects a missing, stale, shared, or foreign listener. Eye-arm unified logs are queried with
`processIdentifier == <exact PID>`, never by process name. Every baseline proves that the installed Eye process
is absent before measurement; because there is no candidate PID in those arms, their Eye log counters are
recorded as zero only after that absence check. Sanitized per-arm unified-log counts must show zero `SCScreenshotManager`, zero
`_SCRemoteQueue_Enqueue`, zero `stream output NOT found`, and exactly one `eye_screen_stream_started`. Non-Eye
arms must contain zero Eye stream starts. The real-call arm cannot proceed until the operator attests both
tracks immediately before and after measurement; the result stores only that boolean, never call content.
Because baselines require quitting Eye, the full bracket correctly
contains three independent Eye process lifetimes and one stream start in each.

The only final classifications are:

- `pass` — the automated bracket passed; the manual and soak gates are still required.
- `Eye no-go` — an Eye arm breached the screenshot, latency, or one-stream threshold.
- `upstream-blocked` — a native baseline or the ChatGPT + Chronicle control is already broken or too slow.
- `invalid` — process state, artifact identity, sample count, or baseline controls were contaminated.

## Before running

- Build, notarize, staple, and install one clean Release candidate in `/Applications/ZBS Eye.app`.
- Keep its adjacent `dist/*.manifest.json` and notarized ZIP. The manifest must match the installed executable,
  source revision, bundle/version/build, Team ID, CDHash, designated requirement, and archive hash.
- Resolve the data root used by this candidate, including a relocated external-volume root. Pass that exact
  existing directory as `--data-root`; the gate canonicalizes it but never reads another root or scans fallback
  ports. A configured external volume must remain mounted throughout the bracket.
- Grant the already-required permissions once through normal macOS UI to Terminal, ZBS Eye, ChatGPT, and
  Chronicle. Do not grant Input Monitoring solely for Eye's hotkey observer: it uses a non-prompting preflight
  and fails open when the existing grant is insufficient. The exact expected number of new permission prompts
  during the run is **0**.
- Put a harmless test surface and the qualification Terminal on the macOS main display. The automated probe
  intentionally captures only that display, so no secondary-display screenshot can be left behind. Do not use
  a private conversation, personal document, or sensitive real call.
- Quit Eye, ChatGPT, and Chronicle. Do not run the gate from an app-owned terminal.

## Automated bracket

From Terminal, in the clean source checkout matching the candidate manifest:

```bash
bash scripts/verify-capture-coexistence.sh \
  --app "/Applications/ZBS Eye.app" \
  --data-root "/absolute/path/to/the/current/ZBS Eye data root" \
  --manifest "dist/ZBSEye-<version>-<build>-<sha>-notarized.manifest.json"
```

The script pauses before every arm. Set exactly the requested state, wait until the static test window is
visible, then press Return. It validates the processes but never changes them itself.

Private output is written with mode 0700 below:

```text
~/Library/Application Support/ZBS Eye Qualification/capture-coexistence/<UTC>-<sha>/
```

The bundle contains the release manifest copy, four-column attempt TSVs, aggregate metric and log-count
summaries, before/after process PID sets, and `result.json`. It contains no screenshots, pixel fingerprints, captured text, audio, database
rows, API tokens, Keychain values, or unredacted logs. Raw unified-log output exists only as a private scratch
file while its four fixed counters are calculated, then is deleted. Never commit this directory. A public
result may contain only the allowlisted identity and aggregate metrics from `result.json`.

## Manual native-shortcut gate

Use the same installed candidate and repeat the exact nine-arm process-state bracket. In every arm (1 through
9), including the Eye-only arm and its neighboring baselines:

- Press Shift-Command-3 ten times. Each capture must happen immediately and contain the state visible at the
  keypress, not a later desktop.
- Press Shift-Command-4 ten times and capture the same fixed test rectangle.
- Press Shift-Command-5 ten times and take a still through Screenshot UI.
- Repeat all three shortcuts ten times with Control held. Verify the clipboard result for 3 and the fixed
  selection for 4; for 5, verify the destination shown by Screenshot UI before capture.
- Count new permission prompts for Eye, ChatGPT, and Chronicle. Expected: Eye `0`, ChatGPT `0`, Chronicle `0`.
- Confirm Eye's status agrees in the compact UI, authenticated `/v1/capture/status`, and MCP `get_status`.
- Confirm the Timeline and Ask show one coverage warning only for a synthetic/known affected interval; missing
  results inside that interval must never be described as proof of inactivity.

Record only pass/fail, prompt counts, and latency observations. Do not retain the screenshots.

## Lifecycle and recovery matrix

With Eye recording, exercise each case once, then repeat it with ChatGPT and Chronicle open:

| Case | Required result |
|---|---|
| Static screen for 10 minutes | Healthy; identical pixels alone never trigger repair. |
| Sleep / wake | Capture resumes once without a new permission prompt. |
| Launch while locked, then unlock | No capture while locked; one verified start after unlock. |
| Lock / unlock | No overlapping replacement and no late false-green state. |
| Attach/detach or rearrange a display | Old generation is rejected; the new display advances. |
| System Audio off | Screen remains healthy; audio stays off. |
| System Audio on | The requested audio leg starts without restarting a healthy screen leg. |
| Quit / relaunch Eye | Recording intent and coverage metadata survive; prompt count remains zero. |
| Repair Capture | A fresh bounded Eye-owned retry episode; no app or global service is restarted. |

The same bounded repair is available through authenticated `POST /v1/capture/repair` and the
`repair_capture` tool in the explicit advanced/full MCP profile. The default read-only MCP profile cannot
discover or call it. All three surfaces repair only Eye-owned legs; none changes TCC, relaunches apps, or
touches a global macOS capture service.

If an external developer-only daemon-loss experiment is needed, run it **last**, after every bracket and
lifecycle result is saved. The qualification script does not perform that experiment. A pass requires Eye to
recover without relaunch and without a new prompt; otherwise classify `Eye no-go`. Log out or restart macOS
afterward before repeating any earlier arm, because the experiment contaminates the baseline.

### Bounded capture-architecture research

A picker-versus-persistent-stream comparison is research, not an automatic production fallback. It may run
once on a separate developer-only candidate using the same 5 + 100 bracket and sanitized metric schema. Record
only p50/p95/max, CPU/memory, freshness, and failure count. Do not change the shipping capture path, add a
hidden preference, or reuse its result in the release candidate without a separate reviewed plan.

## Churn and installed soak

First run 30 minutes of rapid app switching while OCR and both audio legs are active. Perform at least 120
deliberate focus changes (an average cadence of one every 15 seconds or faster) across ChatGPT, Chronicle, an
OCR-heavy app, and an ordinary native app. At each five-minute checkpoint record elapsed time, cumulative
switch count, newest Timeline timestamp, aggregate capture state, both audio-leg states, and open coverage-gap
count. This small receipt proves that “rapid” was actually exercised without retaining captured content.
Timeline must keep advancing, aggregate capture state must remain `healthy`, and no coverage interval may
remain open. Then keep the same candidate installed and recording for two hours. At `+5 minutes`, `+1 hour`,
and `+2 hours`, record only these sanitized values from UI plus authenticated status/MCP:

- aggregate state;
- each requested leg's state, stable reason, generation, and attempt;
- count of automatic recovery episodes since the previous checkpoint;
- count of new permission prompts;
- count of open coverage intervals.

Pass requires zero exhausted episodes, zero new prompts, no interval closed without verified progress, an
advancing Timeline, `healthy` capture, and no open coverage gaps. Automatic recovery is limited to three
non-overlapping attempts after 1, 3, and 10 seconds; any exhausted episode is a failure. The final merge
qualification is complete only after the automated result is `pass`, every manual row passes, the 30-minute
churn passes, and the `+2 hours` checkpoint passes.

## Reruns

Never overwrite or continue a failed session. Fix the cause, establish a fresh baseline (log out or restart if
the native screenshot path was disturbed), and run a new timestamped session against the same artifact or a
new manifest-bound candidate. A shifted control is `invalid`, never a product pass.
