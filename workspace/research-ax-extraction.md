# Ресёрч: почему AX-извлечение текста варьируется (2026-06-03)

> 3 параллельных агента (Chrome/web · GPU-apps · Electron variance). Полные отчёты ниже.
> Это закрывает главный вопрос harness 1a: где AX-first реально работает, а где нужен OCR.

## Сводный вердикт (синтез трёх отчётов)

**«AX-first побеждает на Electron» — неверно как абсолют. Верная рамка: adaptive AX-first +
OCR-fallback, решается per-app в рантайме по content-quality.** Это defensible и это ровно то, что
screenpipe делает плохо (walk-once → преждевременный OCR → 147% CPU на Obsidian).

### Три класса приложений
1. **AX работает** (большая доля рабочего экрана): нативные AppKit/SwiftUI (iTerm2 49k, Mail, Preview,
   Terminal), Electron на DOM-редакторах **CodeMirror/Monaco/ProseMirror/Lexical** (Obsidian 6k, VS
   Code/Codex 34k), браузеры Chrome/Edge/Arc (с retry-walk), Safari (проще всех — дерево по умолчанию),
   Flutter desktop.
2. **OCR-only навсегда** (AX физически не отдаёт текст): GPU-рендереры — **Zed (GPUI), Warp**, вероятно
   Alacritty/kitty/WezTerm/Ghostty; canvas — **Figma, Slack Canvas**; игры (Unity<6.3, Unreal);
   `<canvas>`-области внутри любого Electron.
3. **Per-app лотерея** (зависит от того, как авторизован web-frontend): **Notion=0** (custom block
   widgets + DOM-виртуализация — текста нет в дереве в принципе, не пофиксить timing'ом), **Slack**
   (virtualized list), **Claude desktop=67** (React без text-роли).

### Chrome: AX-класс, не OCR (фикс моих 148 символов)
- Web-текст доступен через **main PID** (renderer/helper PID НЕ нужен — дерево мёржится в browser
  process). Мои 148 = дерево не построено к моменту обхода + timeout 200мс убивал обход до AXWebArea.
- Рецепт: `AXManualAccessibility=true` (fallback `AXEnhancedUserInterface`, игнор `-25205`) → **ждать
  150-300мс / поллить до непустого AXWebArea** → обойти от main PID, проваливаясь через AXGroup к
  **AXStaticText.AXValue**. Активная вкладка активного окна (фоновые часто пустые).
- → Мой v3 (timeout 50мс + budget 2с + retry 250/750/1500/3000) это и чинит.

### Что РЕАЛЬНО строит AX-дерево Electron (а не флаг)
- `AXManualAccessibility=attributeUnsupported` — известный баг Electron #37465 (фикс PR #38102). Флаг —
  бесполезный gate. Реально триггерит: AT-detection (VoiceOver/AXEnhancedUserInterface) ИЛИ
  AXManualAccessibility ИЛИ **сам акт обхода** (lazy realization) + время.
- **Загрязнение машины Никиты подтверждено:** screenpipe/Limitless/superwhisper/krisp/Hammerspoon
  глобально включают a11y → деревья доступны «без флага». На чистой машине нужен наш флаг+retry. Значит
  **наш retry-walk + флаг — это и есть ценность для обычного юзера.**

### Наша дифференциация vs screenpipe (defensible)
1. **retry-walk** после флага (250/750/1500/3000мс) — screenpipe walk-once и сдаётся в OCR.
2. **content-quality gate** (classify по contentChars, не по flag-success и не по суммарному тексту).
3. **per-app capability table**: seed эвристикой (editor-engine: CodeMirror/Monaco→AX; canvas/Notion→OCR),
   confirmed empirically, **invalidated on app-update**. Не «Electron = один bucket».
4. **resolve main vs renderer PID** + walk into AXWebArea.
5. Честный **OCR-tier** для GPU/canvas/virtualized — не притворяться что AX их возьмёт.

---

## Отчёт 1 — Chrome / браузеры (web-текст через AX)

Полный отчёт см. ниже (агент chrome-web-ax). Ключевое: AX-класс, main PID, lazy async build, флаг+
задержка+re-walk, Safari проще, screenpipe=AX-first референс, Rewind=OCR-класс целиком.

## Отчёт 2 — GPU-приложения (Zed/Warp)

Ключевое: AX читает не пиксели, а декларативное дерево, которое приложение строит САМО. GPU-рендеринг
глифов и построение AX-дерева — независимые подсистемы. Zed/GPUI не строит a11y (AccessKit «далеко за
1.0»). Warp — UI не в AX. Контраст: Flutter рисует на GPU, но несёт AccessibilityBridge → AX есть.
Только OCR: GPU-редакторы, GPU-терминалы, игры, canvas.

## Отчёт 3 — Electron variance

Ключевое: Electron НЕ надёжный класс, а per-app лотерея по авторингу web-frontend. CodeMirror/Monaco
(DOM contenteditable) → AX-текст. Notion (custom widgets + virtualization) → 0, и это не пофиксить
(off-screen блоков нет в DOM вообще). Мой harness уже делает правильно (retry-walk + content/chrome
split) — то, что screenpipe не делал. Per-app viability = измеряемая capability, кэшируется,
ре-валидируется на апдейтах.

---

_(Полные тексты трёх отчётов с источниками — в истории сессии / transcript workflow wf_f4a6905b-4d5.
Ключевые источники: Chromium a11y docs, screenpipe #3002, Electron #37465/#38102, Mozilla bug 1664992,
Zed discussions #6576/#8146, jscholes Notion a11y, Rewind teardown.)_
