# Screen-understanding benchmark harness

This is an offline research harness, not a ZBS Eye product subsystem. Every method uses the same
newline-delimited JSON process contract and produces the normalized result schema in `schemas/`.

Security rules:

- Pin the exact source/model revision and seal a complete artifact inventory before it can see a case.
- Run adapters serially with no retries and with `HF_HUB_OFFLINE=1` / `TRANSFORMERS_OFFLINE=1`.
- Materialize canonical absolute roots into `sandbox/adapter.sb` with `materialize_profile.py`, then
  launch every non-Apple adapter through that profile: network denied; model and case roots read-only;
  only the result and temporary roots writable. The template avoids macOS 26's crashing support for
  parameterized `subpath` filters.
- Treat a missing runtime, sandbox denial, crash, malformed line, or timeout as an explicit failure.
- Never copy case media, captions, labels, paths, identifiers, timestamps, prompts, or raw errors into
  the repository or a public report. Only the allowlisted aggregate schema may leave the private root.

`contract_adapter.py` is deliberately synthetic. It verifies the runner lifecycle and fail-closed
behavior without opening the private corpus. On the current qualification Mac, the strict filesystem
profile exits before the malicious canary can prove its boundary. Therefore every third-party adapter is
recorded as `security-unsupported` and is forbidden from opening the private corpus. Offline environment
flags alone are not accepted as a substitute. A future OS/runtime may re-run this qualification.
