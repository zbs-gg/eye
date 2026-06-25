# Changelog

Все заметные изменения ZBS Eye. Формат — по разделам Added / Changed / Fixed.

## [Unreleased] — 2026-06-25

### Fixed
- **Краш живой записи (self-AX reentrancy).** При активной записи ZBS Eye оставался frontmost →
  `CaptureCoordinator` инспектировал собственный процесс → `AXReader` читал наше же SwiftUI-дерево →
  `kAXValue` у нашего `Slider` синхронно вызывал его `@MainActor Binding.get` (`TimelineView.swift:294`)
  прямо на serial-очереди `AXReader` → `dispatch_assert_queue(main)` → `EXC_BREAKPOINT`. Падало внутри
  `AXCore.perform`, до возврата из `await` — поэтому никакой executor-хоп не спасал. Диагноз — Pro-ревью.
  Фикс: `guard pid != ownPID` в `runCycle` + защита в `AXReader.extract/titleOnly`; AX-чтение по роли
  (text → value/title/selected, chrome → title/desc, иначе ничего — не дёргаем `kAXValue` у не-text);
  `Bundle.main` исключён из ScreenCaptureKit (таймлайн не пишет сам себя); `MainActor.preconditionIsolated()`
  после AX-ветки. Откачена тупиковая попытка с custom `SerialExecutor`.

### Added
- **Выбор LLM-модели из LM Studio/Ollama.** В «Подключениях» поле «Модель» — теперь `Picker` из реально
  загруженных моделей (`GET /v1/models`), а не свободный ввод. Авто-подгрузка при открытии, авто-выбор
  первой доступной, fallback-ввод + ↻ если сервер молчит.
- **Пайплайн нотаризации Developer ID** (`scripts/build-notarized.sh` + `docs/NOTARIZE.md`): сборка с
  Hardened Runtime → Developer ID подпись + secure timestamp → `notarytool submit --wait` → `stapler
  staple` → проверка Gatekeeper. На выходе нотаризованный `dist/ZBSEye-notarized-*.zip` (запуск двойным
  кликом, без «Open Anyway»; подпись стабильна — ребилды не сбрасывают TCC-права).

### Changed
- **Решение по раздаче: Developer ID + нотаризация, НЕ Mac App Store.** App Store требует App Sandbox,
  под которым невозможен cross-app Accessibility (ядро извлечения текста), а профиль «вечная память,
  пишет всё» реджектится по приватности — как Rewind/screenpipe, раздача вне App Store. AGENTS.md/README
  обновлены.
