# Slishu — UI / Permissions / Pipes / Connections / Packaging Design

> Дизайн-документ от Plan-агента (оболочка/UI/плагины/коннекторы/упаковка). Часть бандла для Pro.

## 0. Что есть сегодня
Монолит `ContentView.swift` (1531 строка), hand-rolled HStack sidebar (не NavigationSplitView), всё
состояние — разрозненные `@State` на одной гигантской view. `SlishuApp.swift` — WindowGroup + 3-кнопочный
MenuBarExtra. Backend solid: Capture/Audio/Transcription/DB/Server/MCP/SemanticSearch.

Дыры новой версии: **Pipes** = mock `[PipeItem]`, «Настроить» = `// Mock configure sheet`, нулевой
backend. **Connections** = mock, «Подключить» = toggle Bool, нет Keychain/test/config. **Permissions** =
только реактивный `-3801` детект, нет preflight/онбординга. `project.yml`: deployment 14.0, Swift 5,
нет entitlements/LSUIElement/Accessibility usage string.

## 1. App Shell

### 1.1 Структура файлов — см. PLAN.md «Целевая структура файлов».

### 1.2 SlishuApp.swift
```swift
@main struct SlishuApp: App {
    @State private var env = AppEnvironment()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("Slishu", id: "main") {                 // не WindowGroup
            RootWindow().environment(env).task { await env.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar).windowResizability(.contentMinSize).defaultSize(width:1100, height:720)
        MenuBarExtra { MenuBarContent().environment(env) }
            label: { MenuBarLabel(state: env.recording) }
        .menuBarExtraStyle(.window)                     // богатый glass-popover
        Settings { EmptyView() }
    }
}
```
- **`Window(id:)` не WindowGroup** — single-window utility; MenuBar «Открыть» → `openWindow(id:"main")`
  вместо хака `NSApp.windows.first`.
- **`MenuBarExtra(.window)`** — real glass popover: toggle, счётчики, активный порт, варнинги, выход.
- **Корень — один `@Observable AppEnvironment`** через `.environment`, читается
  `@Environment(AppEnvironment.self)`. Убираем антипаттерн (старый `TimelineTabView` брал **14
  биндингов**).

### 1.3 LSUIElement / agent mode
**Рекомендация: обычное приложение с menu-bar присутствием** (`LSUIElement = NO`), окно закрывается без
выхода (сервисы независимы от UI). Чистый TCC-UX. Опц. тумблер «Скрывать из Dock» → runtime
`NSApp.setActivationPolicy(.accessory/.regular)`. Избегаем классической ловушки agent-mode, где
backgrounded-апп не показывает screen-recording промпт.

### 1.4 Lifecycle (`AppEnvironment.bootstrap()`)
1. DB ready. 2. `PermissionsStore.refreshAll()` (preflight). 3. `ServerStore.start()` (реальный порт).
4. `RecordingStore.startIfPermittedAndEnabled()`. 5. `PipeScheduler.resume()`. 6. NSWorkspace
sleep/wake/activity observers. Teardown на `willTerminate`: stop capture (flush last audio), server.stop,
cancel pipe timers.

### 1.5 @Observable паттерн
```swift
@Observable @MainActor final class RecordingStore {
    private(set) var isCapturing = false; private(set) var hasScreenTccError = false
    private(set) var screenFrameCount = 0; private(set) var audioChunkCount = 0
    var pauseByAppEnabled = false
    func toggle() { isCapturing ? stop() : start() }
    func refreshCountsFromDB() async { … }   // GRDB ValueObservation, не Timer.publish(1s)
}
```
Заменить `Timer.publish(every:1.0)` → **GRDB `ValueObservation`** (реактивно, ноль polling).

## 2. Онбординг прав

### 2.1 `PermissionChecker` (чистые пробы)
| Право | Проба (без промпта) | Запрос | Deep-link |
|---|---|---|---|
| Screen Recording | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()` (+рестарт захвата) | `…?Privacy_ScreenCapture` |
| Accessibility | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions([prompt:true])` | `…?Privacy_Accessibility` |
| Microphone | `AVCaptureDevice.authorizationStatus(.audio)` | `requestAccess(.audio)` | `…?Privacy_Microphone` |
| Speech (вторичное) | `SFSpeechRecognizer.authorizationStatus()` | — | — |
```swift
struct PermissionState: Sendable {
    enum Status { case granted, denied, notDetermined, needsRestart }
    var screenRecording, accessibility, microphone, speech: Status
}
```

### 2.2 Проблема `-3801` правильно
`-3801` = SCStreamError «user declined TCC». Ключевое: **после выдачи права процесс надо перезапустить**
для SCK (исторически relaunch; на macOS 15+ часто хватает `CGRequestScreenCaptureAccess` + пересоздание
`SCStream`). Статус `.needsRestart` (preflight==true, но last start вернул -3801) → кнопки
**«Перезапустить захват»** (teardown+recreate SCStream) и **«Перезапустить Slishu»** (relaunch).
Поллинг 1.5с (TCC без KVO); на grant — авто-advance + рестарт захвата для screen.

### 2.3 Flow (первый запуск)
`OnboardingFlow` при `didCompleteOnboarding==false` ИЛИ любое право denied/notDetermined. Шаги:
Welcome → Screen Recording → Accessibility («чтобы читать текст без OCR, точнее и легче для батареи») →
Microphone (опц., можно «только экран») → Done (активный порт + «начать запись»). Переиспользуемый
`PermissionRow` (общий с Settings — не разъезжаются).

### 2.4 Диагностика в Settings
Постоянная панель «Разрешения и диагностика»: те же rows + SCK live error code, last -3801 timestamp,
«Сбросить TCC» (`tccutil reset`, за confirm), «Повторить проверку».

## 3. Timeline + Time-Travel Scrubber (keystone)

### 3.1 `TimelineStore` — ось ВРЕМЯ, не индекс массива
Старый грузил всю историю в массив (HEIC каждые 2с ≈ 1.5–3ГБ/день) — не масштабируется.
```swift
@Observable @MainActor final class TimelineStore {
    var range: ClosedRange<Date>; var cursor: Date; var zoom: Zoom = .hour   // .day/.hour/.tenMin
    private(set) var lane: [FrameTick]; private(set) var current: FrameDetail?
    private(set) var isPlaying = false; var playbackRate: Double = 1.0        // 1×/2×/4×
    func loadRange(_ r: ClosedRange<Date>) async
    func seek(to t: Date) async; func step(_ dir: Step) async; func play()/pause()
}
struct FrameTick: Identifiable, Sendable { let id: Int64; let t: Date; let appId: Int64? }  // ~32 байта
struct FrameDetail: Sendable { let id: Int64; let t: Date; let imageURL: URL
    let appName, bundleId: String; let windowTitle, url: String?; let ocrText: String; let source: TextSource }
```

### 3.2 Что нужно от data/REST агентов
1. Range ticks: `GET /timeline?from&to&bucket=60` → ticks + buckets (count + topApp). In-process:
   `SELECT id, ts, app_id FROM screen_captures WHERE ts BETWEEN ? AND ? ORDER BY ts`.
2. Frame at instant: `GET /frame?at=<iso>` → nearest ≤ at + FrameDetail. In-process:
   `WHERE ts <= ? ORDER BY ts DESC LIMIT 1` + join apps + FTS text.
3. Media bytes: `GET /media/<file>` (есть) или in-process `NSImage(contentsOf:)` напрямую.
**Запрос к data:** добавить `window_title`/`browser_url` в `screen_captures` (миграция), populate в
capture-слое из `frontmostApplication` + AX.

### 3.3 ScrubberView
- **Density strip**: `Canvas`-лента по range. Бар на бакет, высота = число кадров, цвет = доминирующий
  апп (детерминированный из bundleId hash, якоря Indigo/Emerald/Space-Grey). Видно где плотно (встреча,
  кодинг-burst) vs idle.
- **Playhead**: draggable `DragGesture` → `cursor`, `seek` **debounced 60–80мс** на `userInitiated`
  (thumbnail сразу, HEIC+OCR на тик позже).
- **Zoom**: `День/Час/10мин`. **Transport**: play/pause, 1×/2×/4×, step ±1 (`⌥←/→`), «сейчас» (`⇧→`).
  Playback двигает `cursor` на медианную дельту × rate (idle-промежутки промотаются).
- **Crossfade**: `.transition(.opacity)`/`contentTransition(.interpolate)`.

### 3.4 Spotlight-поиск (унифицирован со скруббером)
`SearchStore`: `⌘F`-field, тумблер Полнотекст/Смысл(AI), фильтры app/time/source. **Клик по хиту → `cursor
= result.timestamp`** и переключение в скруббер (поиск и time-travel — одна поверхность, не два экрана).
Запрос к data: расширить `/search` параметрами `apps`/`from`/`to`/`type`.

### 3.5 Миграции (аддитивные, НЕ erase)
**Убрать `eraseDatabaseOnSchemaChange`** (опасно для history-рекордера). `v3_window_url`
(window_title,url), `v4_pipes`, `v5_connections`.

## 4. Pipes — реальный backend

### 4.1 Модель: **(a) markdown+YAML scheduled local-LLM агенты — primary**, JS только опц. escape hatch
Никита ссылается «как у screenpipe» + local LLM (Ollama/MLX). Декларативные cron-таски, дёргающие
локальный REST + local LLM — ложатся на уже построенное, ноль нового рантайма. Инспектируемо/диффабельно/
подписываемо. **JavaScriptCore (option b)** лёгок (~1–2МБ), но даёт sandboxing/security-поверхность и
тяжелее по debug — **не строить в v1**, зарезервировать `kind: script` как точку расширения.
Пайп *потребляет* Connections — чистое разделение секций.

### 4.2 Формат
Папка `~/Library/Application Support/Slishu/Pipes/<id>/`: `pipe.yaml` + `pipe.md` + опц. `icon.png`.
```yaml
id: daily-summary
name: Саммари дня
kind: prompt            # prompt | query
schedule: "0 21 * * *"  # cron
inputs:
  - source: search
    query: "*"
    range: today
    limit: 400
llm: { connection: local-llm, model: llama3.1, promptFile: pipe.md }
output: { connection: obsidian, target: "Daily/{{date}}.md", mode: append }
config:
  - { key: tone, type: enum, options: [краткий, подробный], default: краткий }
permissions: [read_history, call_llm, write_connection]
```

### 4.3 Реестр/хранение
`PipesStore` (@Observable) = папки на диске + таблица `pipes` (runtime state). Config-оверрайды per-pipe
как JSON. **Секреты НЕ здесь** — пайп ссылается на Connection (секрет в Keychain).
```sql
CREATE TABLE pipes(id TEXT PRIMARY KEY, version TEXT, enabled INTEGER, configJson TEXT,
    lastRun DATETIME, nextRun DATETIME, lastStatus TEXT, lastError TEXT, installedAt DATETIME);
CREATE TABLE pipe_runs(id INTEGER PRIMARY KEY AUTOINCREMENT, pipeId TEXT, startedAt DATETIME,
    finishedAt DATETIME, status TEXT, logText TEXT, outputRef TEXT);
```

### 4.4 Исполнение
- **PipeScheduler**: один coordinator, считает `nextRun` из cron (мини-evaluator/DispatchSourceTimer per
  pipe). Fire → `PipeRuntime.run` на background actor.
- **PipeRuntime.run**: resolve inputs (DB/REST) → context → если `kind:prompt` POST в LLM Connection
  (Ollama `/api/generate` / MLX) → output → write в output Connection → `pipe_runs` row.
- **«Запустить сейчас»** для любого пайпа. **Missed-run**: проспал cron → один catch-up на wake, не N раз.

### 4.5 Sandbox/security
Декларативные, не произвольный код. Capability-list (`permissions:` в yaml): нет `write_connection` →
никуда не пишет. Показ caps в install-sheet («будет: читать историю, вызывать local LLM, писать в
Obsidian») — явное согласие. LLM-вызовы только в user-configured Connection endpoints (дефолт local
Ollama `127.0.0.1:11434`), никогда хардкод-облако. Каждый run time-boxed + изолирован в Task; крах →
error row, не роняет capture.

### 4.6 UI
`PipesListView` (glass grid, реальный toggle/статус/nextRun, **рабочая «Настроить»**→`PipeDetailView`).
`PipeDetailView`: рендер `pipe.md`, **schema-driven форма из `config:`** (enum→Picker, string→TextField,
bool→Toggle, connection-ref→Picker совместимых Connections), редактор расписания, «Запустить сейчас»,
live-лог (`pipe_runs.logText`). `PipeInstallSheet`: из bundled examples / «Импортировать папку…» /
будущий registry URL.

### 4.7 Готовые пайпы (вместо 4 mock)
1. **Саммари дня** (prompt, 21:00): сегодняшние OCR+транскрипты → local LLM → append в Obsidian Daily.
2. **Поиск по встречам** (query+prompt): транскрипты где app∈{Zoom,Meet,Slack} → action items →
   Notion/Slack.
3. **Экспорт истории** (query, weekly): диапазон кадров+текста → Markdown/JSON через file Connection (без
   LLM — демо `kind:query`).

## 5. Connections — реальный backend

### 5.1 Таксономия/auth
| Коннектор | Тип | Auth | Egress | Test |
|---|---|---|---|---|
| Obsidian (vault) | FS | путь+bookmark | нет | пишет/удаляет `.slishu-test` |
| Local LLM (Ollama/MLX) | HTTP local | base URL | localhost | `GET /api/tags` |
| Slack | webhook | Incoming Webhook URL (Keychain) | HTTPS | POST тест |
| Notion | API | Internal Integration Token (Keychain) | HTTPS | `GET /v1/users/me` |
| File export | FS | bookmark | нет | write/delete |
**OAuth vs key:** v1 — api-key/token/webhook везде (OAuth тяжёл: redirect URI + loopback listener +
refresh). `ConnectorAuth` enum (`.none/.apiKey/.webhook/.oauth`) — OAuth позже без UI-churn.

### 5.2 Протокол
```swift
protocol Connector: Sendable {
    static var kind: ConnectorKind { get }; var auth: ConnectorAuth { get }
    func test() async throws -> ConnectionHealth        // ok/unauthorized/unreachable/error
    func write(_ payload: ConnectorPayload) async throws
    func query(_ q: ConnectorQuery) async throws -> Data
}
```
Клиенты: ObsidianConnector (FileManager+bookmark), OllamaConnector (URLSession `/api/generate`),
SlackConnector (POST webhook), NotionConnector (Bearer token), FileConnector.

### 5.3 Секреты — Keychain, НЕ UserDefaults
`KeychainStore` (`kSecClassGenericPassword`, `kSecAttrService="com.slishu.SlishuApp"`,
`account=<connectionId>`, `kSecAttrAccessibleAfterFirstUnlock` — для фоновых pipe-runs). API
`set/secret/delete`. DB `connections` хранит только НЕ-секретный конфиг.
```sql
CREATE TABLE connections(id TEXT PRIMARY KEY, kind TEXT, displayName TEXT, configJson TEXT,
    enabled INTEGER, lastTestStatus TEXT, lastTestAt DATETIME);
```

### 5.4 UI
`ConnectionsListView` (реальный health из lastTestStatus, не fake Bool). «Добавить» → kind picker →
`ConnectorConfigSheet` per kind (Obsidian: vault picker; Slack: webhook SecureField + help; Notion: token
SecureField + db id; Ollama: base-URL `127.0.0.1:11434`). Каждый sheet — **«Проверить подключение»**
(`Connector.test()`, inline result). Секреты в `SecureField` → Keychain, не эхо («•••• установлен» /
«Заменить»).

## 6. Settings
1. **Хранилище**: путь (`mediaDirectory`), «Изменить папку…» NSOpenPanel + **security-scoped bookmark**,
   размер на диске (async sum), retention (7/30/90/без + макс GB), `RetentionPruner` (hourly
   DispatchSourceTimer), «Показать в Finder» + DB path.
2. **Транскрипция**: picker MLX(default)/SFSpeech/Whisper.cpp. v1 рабочий — SFSpeech; не-реализованные
   «скоро».
3. **Сервер**: **показ реального активного порта** (`ServerStore.activePort`), base URL, copy, MCP hint,
   рестарт, preferred-port (дефолт `11435`).
4. **Приватность**: опц. **пауза по приложению** (multi-select; frontmost∈set → скип кадра, hook в
   capture перед save) — НЕ блэклист по умолчанию. + smart auto-pause тумблеры.
5. **Запуск при логине**: `SMAppService.mainApp.register()/unregister()`.
6. **О приложении**: AppIcon (Obsidian Acoustic Sphere), версия, «N кадров / M часов аудио».
`SettingsStore`: скаляры в UserDefaults (не-секрет), доступ к папкам — bookmarks, секреты — Keychain.

## 7. Упаковка

### 7.1 project.yml
- `deploymentTarget: "15.0"` (было 14.0). `SWIFT_VERSION: 6.0` + `SWIFT_STRICT_CONCURRENCY: complete`
  (было Swift 5). LSUIElement-handling + Dock-toggle. Usage strings: ScreenCapture (есть), Microphone
  (есть), **+ Speech**, Accessibility (нет формального ключа — документировать в онбординге),
  AppleEvents (если browser-URL через AppleScript). Entitlements файл + `CODE_SIGN_ENTITLEMENTS`.
  CFBundleIconName/AppIcon.

### 7.2 Sandbox: **Hardened Runtime, БЕЗ App Sandbox**
SCK full-display + Accessibility (cross-app AX) фундаментально несовместимы с App Sandbox; локальный TCP
сервер + произвольное хранилище на внешнем SSD тоже. **Hardened Runtime ON, App Sandbox OFF** (так
шипят Rewind/screenpipe-класс). Дистрибуция = Developer ID + **нотаризация** (не MAS — он форсит
sandbox и отклонит категорию).
```
Slishu.entitlements (hardened, non-sandboxed):
  com.apple.security.cs.allow-jit                     YES   (JSC позже)
  com.apple.security.cs.disable-library-validation    YES   (MLX dylibs)
  com.apple.security.device.audio-input               YES   (микрофон)
  com.apple.security.automation.apple-events          YES   (browser URL, опц.)
  # NO com.apple.security.app-sandbox
  # Screen Recording & Accessibility — TCC runtime grants, не entitlements
```

### 7.3 Signing/notarization/login
Developer ID Application, `--options runtime`, embed entitlements. Нотаризация `notarytool` +
`stapler staple`. DMG/zip. Launch at login — `SMAppService.mainApp` (без отдельного helper). AppIcon
`.appiconset` (16→1024) из `workspace/slishu_isolated_icon_*.png` (чистая сфера на белом, 1024²).

## 8. Build / sequencing
1. Shell skeleton (AppEnvironment+stores, NavigationSplitView, MenuBar, lifecycle поверх singletons).
2. Permissions (Checker+Store+онбординг+диагностика; -3801→needsRestart). 3. Timeline/scrubber
(TimelineStore + ScrubberView; DB v3 + range/frame REST). 4. **Connections до Pipes** (KeychainStore,
Connector+5 клиентов, v5, UI+test). 5. Pipes (формат, Engine/Scheduler/Runtime, v4, UI, 3 пайпа).
6. Settings retention/transcription/port/login. 7. Packaging (entitlements, Swift6/macOS15, AppIcon,
sign+notarize).
Запросы к sibling-агентам: (a) миграции v3/v4/v5 + убрать erase; (b) REST `/timeline`,`/frame`,
`q/apps/from/to/type` на `/search`; (c) capture populate `window_title`/`browser_url` + опц. per-app pause.
