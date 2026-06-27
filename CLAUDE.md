@AGENTS.md
Claude-specific: enable the swift-lsp plugin in this repo (it is off globally); swiftlint is advisory, not a gate (it must never be blocking). There is no test target yet — verification is live (REST battery, MCP, sqlite reconciliation) plus `bash scripts/verify.sh` (build gate).
After a non-trivial commit, run the `post-commit-verifier` subagent on top of the build gate from ## Verify.
