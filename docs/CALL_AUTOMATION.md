# Local Call Automation

ZBS Eye can notify one service on the same Mac after a recorded call ends and after its final transcript becomes ready or terminally fails. The notification is a small signed hint, not the call itself. The receiver fetches authoritative evidence through Eye's existing authenticated MCP or REST API.

The integration is disabled by default and can only send to `http://127.0.0.1:<port>/<path>`. It never follows redirects and never sends transcript text, audio, screenshots, local paths, titles, OCR, API tokens, or the signing secret.

## Events

| Type | Meaning |
|---|---|
| `call.ended` | The Call Envelope end boundary and final transcript job are durable. Transcription may still be pending. |
| `call.transcript.ready` | A whole-call final revision is now the Preferred Final Transcript. |
| `call.transcript.failed` | The final job exhausted its automatic attempts and is durably failed. |
| `call.automation.test` | Synthetic setup check. It has no call subject or call data. |

Real call events use a typed `subject` such as `call:42`. A receiver should treat the event as a wake-up hint, then call `get_call` and `read_call_transcript` over MCP, or the equivalent authenticated REST routes. Delivery is at-least-once: the same event ID may arrive again after a crash or ambiguous acknowledgement.

## Run the reference receiver

The repository includes a dependency-free receiver that verifies signatures, keeps durable deduplication state in SQLite, and emits one compact JSON line per accepted event to stdout. It does not execute commands or contact another service.

```bash
python3 examples/call-automation-receiver.py --port 8765 --prompt-secret
```

Paste the copied secret into the hidden prompt. For an unattended local harness, pass
`--secret-file /path/to/secret` instead; the receiver rejects files readable by group or other users.
The environment variable `ZBS_EYE_WEBHOOK_SECRET` remains available for process supervisors, but putting a
secret directly in an exported shell command is discouraged because it can enter shell or terminal history.

In Eye, open **Automations → After a call**, set the receiver to `http://127.0.0.1:8765/`, save it, and press **Test**. A successful test prints one JSON line and Eye shows the delivery result.

The receiver's stdout is the vendor-neutral handoff to a supervising harness. The harness can parse the event, deduplicate again by `id`, and give the typed call ID to an MCP-enabled agent. Eye itself does not launch Codex, Claude, OpenClaw, a shell, or another app.

The receiver stores accepted IDs at `~/.local/share/zbs-eye-call-receiver.sqlite3`. They remain until explicitly purged because Eye can retry an undelivered event after a long outage:

```bash
python3 examples/call-automation-receiver.py --port 8765 --prompt-secret --purge-deduplication
```

Purging intentionally forgets replay protection for old event IDs. Do it only when old events can no longer trigger a harmful duplicate action.

## Wire contract

Eye sends a JSON body shaped like CloudEvents 1.0:

```json
{
  "specversion": "1.0",
  "dataschema": "zbseye://schemas/call-automation/v1",
  "id": "018f...",
  "source": "zbseye://calls",
  "type": "call.transcript.ready",
  "subject": "call:42",
  "time": "2026-07-17T12:00:00Z",
  "data": {
    "state": "ready",
    "degraded": false,
    "revisionId": 17
  }
}
```

The versioned `dataschema` is the application contract. `call.ended` data contains `state`,
`interrupted`, and `degraded`; `call.transcript.ready` contains `state`, `degraded`, and `revisionId`;
`call.transcript.failed` contains `state`, a redacted `errorCode`, and `attempt`. The synthetic test event
contains only `{"status":"test"}` and has no `subject`.

Headers:

- `X-ZBS-Eye-Event-ID`: identical to body `id`.
- `X-ZBS-Eye-Delivery-Timestamp`: Unix seconds for this delivery attempt.
- `X-ZBS-Eye-Signature`: `sha256=<hex HMAC-SHA256>`.

The signed bytes are:

```text
<delivery timestamp>.<exact request body bytes>
```

A receiver must:

1. Reject a timestamp more than five minutes from its current clock.
2. Compute HMAC-SHA256 over the exact bytes and compare in constant time.
3. Require the header and body event IDs to match.
4. Durably remember accepted event IDs for its full operating lifetime unless the operator explicitly purges them.
5. Persist acceptance before returning 2xx.

Eye treats every 2xx as delivered. Network failures and HTTP 408, 425, 429, or 5xx retry with capped backoff. Other 4xx responses become a visible blocked state in Automations until the person retries or corrects the receiver. A `Retry-After` hint may be honored within Eye's safety cap.

## Configuration behavior

- Disabling the hook suspends pending delivery and creates no new events while disabled.
- Enabling later does not backfill calls completed while disabled.
- Changing the receiver with an undelivered backlog requires confirmation. Eye atomically discards the old receiver's pending/blocked rows before saving the new endpoint, so private lifecycle facts are never silently redirected.
- Erasing a call suppresses its undelivered events during the initial erase transaction and removes all remaining event metadata when erasure completes.
- The signing secret lives in the macOS data-protection Keychain. Eye never logs or exposes it through REST/MCP.
