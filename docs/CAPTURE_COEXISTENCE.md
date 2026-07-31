# Capture coexistence qualification

This gate answers one release question: does the exact installed ZBS Eye candidate make ordinary macOS
screenshots slower, stale, or unavailable when Eye and Codex both have Screen Recording access?

It is a release qualification, not a repair tool. It never changes macOS permissions, launches or quits an
app, restarts a daemon, or sends a signal to another process. The operator creates each bracket state. Run it
from Terminal so Codex can be genuinely absent during the baseline arms.

## What is measured

The automated bracket is fixed:

1. Baseline A — Eye quit, Codex quit.
2. Eye — installed Eye running, Codex quit.
3. Baseline B — Eye quit, Codex quit.
4. Codex — Eye quit, Codex running.
5. Baseline C — Eye quit, Codex quit.
6. Eye + Codex — both running.
7. Baseline D — Eye quit, Codex quit.

Every arm performs 5 warm-ups and 40 measured `/usr/sbin/screencapture` attempts. Each attempt has a hard
one-second watchdog; each image must exist and decode through `sips`, then it is deleted immediately. In Eye
arms the script verifies both before and after measurement that recording is armed and coarse capture health
is `healthy`. The report retains only attempt number and latency. This automated bracket measures latency,
decodability, and active Eye health; current-state visual freshness remains a blocking manual shortcut check. A run
passes only when every attempt is at most 1,000 ms, the nearest-rank p95 attributable delta for each active
arm is at most 200 ms, and the baseline controls remain within 200 ms of one another.

The only final classifications are:

- `pass` — the automated bracket passed; the manual and soak gates are still required.
- `Eye no-go` — Eye alone or Eye + Codex breached the product threshold.
- `upstream-blocked` — the native baseline or Codex-only arm is already broken or too slow.
- `invalid` — process state, artifact identity, sample count, or baseline controls were contaminated.

## Before running

- Build, notarize, staple, and install one clean Release candidate in `/Applications/ZBS Eye.app`.
- Keep its adjacent `dist/*.manifest.json` and notarized ZIP. The manifest must match the installed executable,
  source revision, bundle/version/build, Team ID, CDHash, designated requirement, and archive hash.
- Grant Screen Recording once to Terminal, ZBS Eye, and Codex through normal macOS UI. This qualification is
  for permission persistence, so the exact expected number of new permission prompts during the run is **0**.
- Put a harmless static test window on screen. Do not use a private conversation or personal document.
- Quit Eye and Codex. Do not run the gate from a Codex-owned terminal.

## Automated bracket

From Terminal, in the clean source checkout matching the candidate manifest:

```bash
bash scripts/verify-capture-coexistence.sh \
  --app "/Applications/ZBS Eye.app" \
  --manifest "dist/ZBSEye-<version>-<build>-<sha>-notarized.manifest.json"
```

The script pauses before every arm. Set exactly the requested state, wait until the static test window is
visible, then press Return. It validates the processes but never changes them itself.

Private output is written with mode 0700 below:

```text
~/Library/Application Support/ZBS Eye Qualification/capture-coexistence/<UTC>-<sha>/
```

The bundle contains the release manifest copy, latency TSVs, a metric summary, and `result.json`. It contains
no screenshots, captured text, audio, database rows, API tokens, Keychain values, or unredacted logs. Never
commit this directory. A public result may contain only the allowlisted identity and aggregate metrics from
`result.json`.

## Manual native-shortcut gate

Use the same installed candidate and the same seven-state bracket. For every state:

- Press Shift-Command-3 ten times. Each capture must happen immediately and contain the state visible at the
  keypress, not a later desktop.
- Press Shift-Command-4 ten times and capture a fixed test rectangle.
- Press Shift-Command-5 ten times, then use both the still-image button and the configured immediate shortcut.
- Count new Screen Recording prompts for Eye and Codex. Expected: Eye `0`, Codex `0`.
- Confirm Eye's status agrees in the compact UI, authenticated `/v1/capture/status`, and MCP `get_status`.
- Confirm the Timeline and Ask show one coverage warning only for a synthetic/known affected interval; missing
  results inside that interval must never be described as proof of inactivity.

Record only pass/fail, prompt counts, and latency observations. Do not retain the screenshots.

## Lifecycle and recovery matrix

With Eye recording, exercise each case once, then repeat it with Codex open:

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
| Repair Capture | One bounded Eye-owned retry; no app or global service is restarted. |

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
once on a separate developer-only candidate using the same 5 + 40 bracket and sanitized metric schema. Record
only p50/p95/max, CPU/memory, freshness, and failure count. Do not change the shipping capture path, add a
hidden preference, or reuse its result in the release candidate without a separate reviewed plan.

## Installed soak

Keep the same candidate installed and recording for 24 hours. At `+5 minutes`, `+1 hour`, `+4 hours`, and
`+24 hours`, record only these sanitized values from UI plus authenticated status/MCP:

- aggregate state;
- each requested leg's state, stable reason, generation, and attempt;
- count of automatic recovery episodes since the previous checkpoint;
- count of new permission prompts;
- count of open coverage intervals.

Pass requires zero exhausted episodes, zero new prompts, no interval closed without verified progress, and no
more than one automatic recovery per hour. The final release decision is allowed only after the automated
result is `pass`, every manual row passes, and the `+24 hours` checkpoint passes.

## Reruns

Never overwrite or continue a failed session. Fix the cause, establish a fresh baseline (log out or restart if
the native screenshot path was disturbed), and run a new timestamped session against the same artifact or a
new manifest-bound candidate. A shifted control is `invalid`, never a product pass.
