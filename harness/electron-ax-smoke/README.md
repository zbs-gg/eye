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

## Как читать результат
Главный вопрос: **сколько твоих Electron-приложений дают `quality` ≥ `partialUseful` с приемлемым
`cpuDeltaTargetApp`?** Сводка в конце stderr печатает `useful (full/partial): N/M`.
- Если большинство `fullUseful`/`partialUseful` и cpuΔ небольшой → ставка держится, идём строить ядро.
- Если много `titleOnly`/`none`/`attributeUnsupported` → AX-first на Electron не выходит, нужно
  пересмотреть (больше OCR, либо принять что часть аппов только-OCR).

Пришли мне получившиеся JSON (или они уже в `workspace/`) — разберу матрицу и зафиксирую решение в плане.

## Замечания
- `apiDisabled` в `manualSetError` = у harness нет Accessibility-прав (см. шаг 3).
- `cpuDeltaTargetApp` грубый (sampling-интервал 0.4с) — индикатор, не точное измерение.
- Telegram Desktop (tdesktop) — Qt, не Electron; нативный Telegram для Mac — Swift. Оба попадут в
  матрицу как `isElectron=false`, но их AX-quality тоже полезно знать.
