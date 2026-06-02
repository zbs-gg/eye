# Electron AX Smoke Harness (Slishu — blocking harness 1a)

**Зачем.** Это самый важный из 4 blocking-harness'ов из ревью Pro. Он проверяет на **твоей реальной
машине** (macOS 26 Tahoe, твои VS Code/Obsidian/Slack/Telegram/Chrome), действительно ли установка
флагов `AXManualAccessibility` + `AXEnhancedUserInterface` даёт **useful** accessibility-дерево, а не
пустое/только-тулбар. От этого зависит вся продуктовая ставка Slishu: если на Electron AX честно
работает — мы легче screenpipe; если нет — придётся падать в OCR и переосмыслить дифференциатор.

Harness НЕ записывает ничего и НЕ часть приложения — это отдельная диагностическая программа.

## Что он мерит (на каждое приложение)
- `manualSetError` / `enhancedSetError` — что вернула установка флага (`success` /
  `attributeUnsupported` / `cannotComplete` / …).
- `firstNonEmptyMs` / `firstUsefulTextMs` — через сколько мс после флагов дерево стало непустым /
  набрало полезный текст (ретраи 250/750/1500/3000мс).
- `nodeCount`, `textCharCount`, `focusedTextChars`, `webAreaFound`, `url`, `windowTitle`.
- `cpuDeltaTargetApp` — насколько вырос CPU **самого** приложения от того, что мы заставили его строить
  AX-дерево (грубо, через `proc_pid_rusage`). Если +X% большой — юзер обвинит Slishu в разряде батареи.
- `quality`: `none | titleOnly | partialUseful | fullUseful | timedOut | sickPID`.
- Контекст хоста: macOS, активен ли VoiceOver, какие оконные менеджеры запущены (Rectangle и т.п.).

## Как запустить

1. **Открой приложения**, которые хочешь проверить: VS Code, Obsidian, Slack, Telegram, Chrome, Arc,
   Discord, Notion — что используешь. Желательно с реальным контентом (открытый файл/чат/страница).

2. Собери release-версию:
   ```
   cd ~/ai/slishu/harness/electron-ax-smoke
   swift build -c release
   ```

3. Запусти (первый раз попросит Accessibility-права):
   ```
   ./.build/release/ElectronAXSmoke --out ~/ai/slishu/workspace/ax-smoke-conservative.json
   ```
   Появится системный диалог **Privacy & Security → Accessibility** — выдай доступ **Терминалу**
   (или iTerm), затем перезапусти команду. Права нужны процессу, который запускает бинарь.

4. Прогон занимает ~4–5с на приложение (ретраи). В stderr идёт live-прогресс и сводка по Electron,
   в JSON — полная матрица.

### Рекомендуемые прогоны (покрыть матрицу Pro)
```
# базовый — все запущенные приложения, conservative
./.build/release/ElectronAXSmoke --out ~/ai/slishu/workspace/ax-smoke-conservative.json

# агрессивный — оба флага сразу, для сравнения
./.build/release/ElectronAXSmoke --mode aggressive --out ~/ai/slishu/workspace/ax-smoke-aggressive.json

# focused-editor: сделай конкретное окно активным и прогони только его
#   (лучший замер текста из главного редактора/веб-области)
./.build/release/ElectronAXSmoke --frontmost --out ~/ai/slishu/workspace/ax-smoke-vscode-frontmost.json
```
Для `--frontmost` переключайся на нужное приложение перед запуском (у тебя ~2с до начала пробы — или
запускай из второго окна терминала). Прогони по очереди для VS Code (с открытым большим файлом и
выделенным текстом), Obsidian, Slack (с открытым каналом), Chrome (на тяжёлой странице).

## Как читать результат (v2 — честные метрики)
v1 маркировал почти всё `fullUseful`, считая ВЕСЬ текст (включая кнопки/меню). v2 различает:
- **`contentChars`** — текст из content-ролей (TextArea/TextField/WebArea/длинный StaticText) = реальный
  контент. **Это и есть честная метрика.**
- **`chromeChars`** — текст из кнопок/меню/табов = UI-chrome (не ценность).
- **`textSample`** — первые ~700 символов извлечённого контента: глазами проверь, это контент диалога/
  редактора или «File / Edit / Settings».
- **`preFlagsTextChars`** — был ли текст ДО установки флага. Если высокий → дерево уже было доступно
  (accessibility включена чем-то другим), и наш флаг ни при чём.

Главный вопрос: **сколько Electron-приложений дают `quality` ≥ `partialUseful` ПО КОНТЕНТУ**, и
`textSample` — это реально контент, а не chrome?

### ⚠️ Загрязнение эксперимента (критично)
Если на машине запущены **screenpipe, Limitless, superwhisper, krisp, Hammerspoon, VoiceOver, Raycast**
и т.п. — они глобально держат accessibility включённой, и «дерево доступно без флага» может быть НЕ
нашей заслугой. Harness печатает их в `otherAXConsumers` и предупреждает.

**Для честного «холодного» замера:** закрой эти инструменты (особенно screenpipe/Limitless/superwhisper/
krisp/Hammerspoon) и перепрогони. Сравни два прогона — если без них Electron-деревья просели → значит на
чистой машине нам придётся самим поднимать accessibility (и тут проверяется, реально ли помогает флаг).

### Идеальный набор прогонов
```
# 1) «грязный» (как есть, со всеми инструментами) — уже сделан
# 2) «чистый»: закрой screenpipe/Limitless/superwhisper/krisp/Hammerspoon, потом:
./.build/release/ElectronAXSmoke --out ~/ai/slishu/workspace/ax-smoke-clean.json
# 3) focused-editor: открой VS Code с большим файлом + ВЫДЕЛИ кусок текста, сделай активным:
./.build/release/ElectronAXSmoke --frontmost --out ~/ai/slishu/workspace/ax-smoke-vscode.json
# (повтори --frontmost для Obsidian с заметкой, Slack с каналом, Chrome на статье)
```

Пришли JSON (они в `workspace/`) — разберу `contentChars` + `textSample` и зафиксирую решение в плане.

## Замечания
- `apiDisabled` в `manualSetError` = у harness нет Accessibility-прав (см. шаг 3).
- `cpuDeltaTargetApp` грубый (sampling 0.4с) — индикатор, не точное измерение.
- `contentChars`/`chromeChars` — эвристика по ролям AX; не идеальна, но отделяет контент от chrome.
- Нативные приложения (Finder/Preview/iTerm) ожидаемо дают много контента — нас интересуют именно
  Electron (`isElectron=yes`) и веб-области.
