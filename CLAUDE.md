@AGENTS.md
Claude-специфика: плагин swift-lsp включать в этом репо (глобально off); swiftlint — advisory, не гейт (нельзя блокирующим). Тест-таргета пока нет — верификация live (REST-батарея, MCP, sqlite-сверка) + `bash scripts/verify.sh` (build-гейт).
После нетривиального коммита — subagent `post-commit-verifier` поверх build-гейта из ## Verify.
