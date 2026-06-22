# ZBS Eye — борда (где мы / сделано / делать)

> Сведено из GitHub + Codex + claude-mem + репо (2026-06-22, workflow-сверка). Стратегия v1.0/v1.5 —
> в корневом `ROADMAP.md` (из PR #4). Этот файл — живой статус, грумится автономно (`workspace/groom/`).

## Где мы

`main` = полный продукт **v0.1+v0.2** (захват экран+аудио, гибрид-поиск FTS5+e5 cross-lingual,
timeline, REST+MCP, relocatable storage + iCloud-бэкап, retention «вечно», импорт, daily-summary,
ребренд в доках). Паритет с origin/main, пушить нечего. **Два открытых потока не в main:**
- **PR #4** (самое продвинутое, не смержено) — код-ребренд + RAG-фича + Автоматизации + стратег-роадмап.
- **roadmap-groom** (эта ветка) — автономный груминг борды.

Codex по коду Eye не писал (его сессии — Garden/Pulse).

## Сделано (verified)

Захват (CaptureCoordinator idle/active/burst, FramePipeline HEIC+phash, AX+OCR per-app) · аудио (mic+
system, VAD, on-device SFSpeech) · гибрид-поиск (FTS5+e5 384d RRF, ru↔en, mean-pooling) · timeline
window-zoom · REST `/v1` (127.0.0.1, Bearer, ноль egress) + MCP stdio · хранилище (relocatable +
iCloud-бэкап LZFSE keep-N + size-tracking + keychain-фикс; миграция 50609 кадров+897 медиа, 0 потерь) ·
retention «вечно» + footgun-гвард · **e5 в бандле** (egress закрыт) · импорт screenpipe · daily-summary ·
ребренд Slishu→ZBS Eye (PR#3) + стабильная подпись (PR#2) + v0.2-хвосты (PR#1).

## В полёте

| Поток | Где | Статус | Блокер |
|---|---|---|---|
| Код-ребренд `SlishuApp→ZBSEyeApp` + RAG «Спроси свою память» (AskView/Store/Service) + pipe→Автоматизации + корневой ROADMAP v1.0/v1.5 | **PR #4** (`claude/macos-screen-capture-app-yftoxj`, +830/−320, 100 файлов, MERGEABLE/CLEAN) | OPEN | **Нигде не компилировался** (среда без Xcode). Перед merge: `xcodegen && xcodebuild -scheme ZBSEye build` на Mac + перевыдать TCC (новый бандл) |
| Автогруминг борды | ветка `roadmap-groom` | auth-фикс внесён (✅ проверен), готова к merge | — |

## Делать (к v1.0 / v1.5)

| # | Item | P | Почему |
|---|---|---|---|
| 1 | **Собрать+смержить PR #4** | P0 | Разблокирует канонические имена ZBSEye + RAG-фичу; риск опечаток rename без сборки |
| 2 | **Нотаризация (Developer ID, $99)** | P0 | Без неё друзья-непрограммисты упираются в Gatekeeper; Apple-recall = риск-таймер, скорость важна |
| 3 | **Проверить audio-semantic ru↔en по звонкам** | P1 | Расхождение: PR#4-ROADMAP помечает ✅ (vec_transcripts), claude-mem #8857 — «векторов нет». Верифицировать на данных |
| 4 | **Sparkle авто-апдейт** | P1 | Без него раздача друзьям = ручная переустановка |
| 5 | **XCTest-таргет** | P1 | Сейчас верификация ручная; rename PR#4 + AskService особенно опасны без тестов |
| 6 | **Honest MCP errors + явная read-only граница** | P1 | Канон «честный UI»; и отстройка от screenpipe computer-use |
| 7 | VAD речь-vs-музыка · полировка AX-глубины · v1.5 «живой суфлёр» (overlay) | P2 | После v1.0, на железе/в поле |
| 8 | Хвосты: убрать 921MB `Slishu.replaced-…` · audio dedup (366 дублей по ts,channel) · source_id мультимонитор | P2 | Мелочи/уборка |

## Сознательно НЕ делаем
task-mining · computer-use evals / actuation · capture-SDK на продажу · Windows Recall parity — B2B-слежка, против ниши «личной памяти».

## План консолидации веток
1. PR #4 → собрать на Mac, починить ошибки rename → squash-merge в main (разблокирует ZBSEye-имена).
2. `roadmap-groom` → merge в main (all-additions, без конфликта; auth-фикс уже внесён).
3. `git branch -d v0.2-tails` (полностью в main). Удалить remote `claude/…` (при merge PR#4) и `roadmap-groom`.
