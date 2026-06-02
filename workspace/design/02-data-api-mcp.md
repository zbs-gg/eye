# Slishu — Дизайн слоёв данных, поиска, REST, MCP и транскрипции

> Дизайн-документ от Plan-агента (данные/поиск/API/MCP/транскрипция). Часть бандла для ChatGPT 5.5 Pro.

## 0. Отправная точка (баги старого кода)
- `SlishuDatabase`: GRDB 6.29, DatabasePool, WAL, миграции; но `eraseDatabaseOnSchemaChange` в DEBUG,
  нет retention, нет `windowTitle/browserUrl/source`, FTS-триггеры неполные (текст вставляется руками).
- `SlishuSemanticSearch`: NLEmbedding + ручной косинус, brute-force, медленно.
- `SlishuServer`: FlyingFox; **баг порт-поиска** (`self.server` ставится ДО `start()`); нет различения
  EADDRINUSE; ручная сборка JSON строками.
- `SlishuMCP`: ручной JSON-RPC, `try!` в `safeSerialize`, 3 инструмента, нет stdio.
- `SlishuTranscriptionManager`: жёстко SFSpeechRecognizer, нет протокола, нет MLX, нет отмены/очереди.
- `Package.resolved` уже содержит официальный MCP SDK + eventsource → SSE доступен.

## 1. Схема SQLite (GRDB)

### 1.1 Решения
- **Единая `text_blocks`** (вместо `ocr_elements`) с полем `source` (`ax`|`ocr`) — убирает костыль
  «AX-текст как фейковый OCR-элемент с bbox=0».
- **FTS5 синхронизируется ТОЛЬКО триггерами** (content-rowid), не ручными INSERT — убирает рассинхрон
  и декартово произведение.
- **external content FTS5** (`content='text_blocks', content_rowid='id'`) — индекс без дублирования
  текста, ~50% экономии.
- Время — **Unix epoch INTEGER (мс)**, не ISO-строка.

### 1.2 DDL (миграция v1)
```sql
CREATE TABLE apps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bundle_id TEXT NOT NULL UNIQUE, name TEXT NOT NULL);

CREATE TABLE screen_captures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,                       -- epoch ms
    app_id INTEGER REFERENCES apps(id) ON DELETE SET NULL,
    window_title TEXT, browser_url TEXT,
    monitor_id TEXT NOT NULL, relative_path TEXT NOT NULL,
    width INTEGER, height INTEGER, bytes INTEGER);
CREATE INDEX idx_sc_ts ON screen_captures(ts);
CREATE INDEX idx_sc_app_ts ON screen_captures(app_id, ts);

CREATE TABLE text_blocks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    capture_id INTEGER NOT NULL REFERENCES screen_captures(id) ON DELETE CASCADE,
    source TEXT NOT NULL,                      -- 'ax' | 'ocr'
    text TEXT NOT NULL, confidence REAL NOT NULL DEFAULT 1.0,
    bbox_x REAL, bbox_y REAL, bbox_w REAL, bbox_h REAL);
CREATE INDEX idx_tb_capture ON text_blocks(capture_id);

CREATE TABLE audio_captures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL, relative_path TEXT NOT NULL,
    duration_sec REAL NOT NULL, channel TEXT NOT NULL DEFAULT 'mic');
CREATE INDEX idx_ac_ts ON audio_captures(ts);

CREATE TABLE transcriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    audio_id INTEGER NOT NULL REFERENCES audio_captures(id) ON DELETE CASCADE,
    text TEXT NOT NULL, language TEXT NOT NULL, speaker TEXT,
    start_offset REAL, end_offset REAL, engine TEXT NOT NULL);
CREATE INDEX idx_tr_audio ON transcriptions(audio_id);

CREATE TABLE embeddings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,                        -- 'screen' | 'audio'
    ref_id INTEGER NOT NULL, model TEXT NOT NULL, dim INTEGER NOT NULL,
    vector BLOB NOT NULL,                      -- Float32 LE, нормализованный
    UNIQUE(kind, ref_id, model));
CREATE INDEX idx_emb_ref ON embeddings(kind, ref_id);
```

### 1.3 FTS5 external-content + триггеры БЕЗ декартова
```sql
CREATE VIRTUAL TABLE text_fts USING fts5(
    text, content='text_blocks', content_rowid='id',
    tokenize="unicode61 remove_diacritics 2");
CREATE TRIGGER text_blocks_ai AFTER INSERT ON text_blocks BEGIN
    INSERT INTO text_fts(rowid, text) VALUES (new.id, new.text); END;
CREATE TRIGGER text_blocks_ad AFTER DELETE ON text_blocks BEGIN
    INSERT INTO text_fts(text_fts, rowid, text) VALUES('delete', old.id, old.text); END;
CREATE TRIGGER text_blocks_au AFTER UPDATE ON text_blocks BEGIN
    INSERT INTO text_fts(text_fts, rowid, text) VALUES('delete', old.id, old.text);
    INSERT INTO text_fts(rowid, text) VALUES (new.id, new.text); END;
-- аналогично transcription_fts на transcriptions
```
**Фикс старого бага:** поиск `FROM text_fts JOIN text_blocks tb ON tb.id=text_fts.rowid JOIN
screen_captures c ON c.id=tb.capture_id WHERE text_fts MATCH ?`. Связь rowid→id строго 1:1. Дедуп
кадров `GROUP BY c.id` с `MIN(rank)`, не JOIN-ом всех элементов (который давал N×M).
Альтернатива — денормализованная `fts_text` прямо в `screen_captures` (FTS 1:1 к кадру by
construction); `text_blocks` остаётся для bbox/highlight.

### 1.4 GRDB конфиг
```swift
var config = Configuration()
config.qos = .utility; config.maximumReaderCount = 5
config.prepareDatabase { db in
    try db.execute(sql: "PRAGMA journal_mode = WAL")
    try db.execute(sql: "PRAGMA synchronous = NORMAL")
    try db.execute(sql: "PRAGMA busy_timeout = 5000")
    try db.execute(sql: "PRAGMA cache_size = -20000")     // ~20 MB
    try db.execute(sql: "PRAGMA mmap_size = 268435456")   // 256 MB
    try db.execute(sql: "PRAGMA foreign_keys = ON")
    SlishuVectorExtension.loadIfEnabled(db)               // sqlite-vec
}
let pool = try DatabasePool(path: dbURL.path, configuration: config)
```
`DatabasePool` (не Queue) обязателен: capture пишет 24/7, REST/MCP читают параллельно. Убрать
`eraseDatabaseOnSchemaChange` (или гейтить `SLISHU_DEV_WIPE`). Миграции аддитивные.

## 2. Векторный поиск

### 2.1 Сравнение для «месяцы 24/7» (сотни тыс.–млн строк)
| Подход | 1M векторов | Память | Вердикт |
|---|---|---|---|
| BLOB + brute-force в Swift (текущий) | секунды, чтение сотен МБ | высокая | не масштабируется |
| BLOB + Accelerate (vDSP/BNNS) + пред-норм | 50–150мс на 1M @384 если mmap | средняя | переходный вариант, всё ещё линейно |
| **sqlite-vec (vec0) в GRDB** | десятки мс, brute KNN в C | низкая (на диске) | **рекомендую** |
| Apple-native | нет готового ANN-индекса | — | только примитивы |

**Рекомендация: sqlite-vec.** Грузится через `sqlite3_auto_extension(sqlite3_vec_init)` ДО открытия
пула или в `prepareDatabase`. Лёгкая зависимость (один C-файл). KNN brute-force с SIMD; для целевых
объёмов десятки мс. Гибридные фильтры по времени/app в одном SQL.
```sql
CREATE VIRTUAL TABLE vec_embeddings USING vec0(
    ref_kind TEXT PARTITION KEY, embedding FLOAT[384]);
SELECT v.rowid, v.distance FROM vec_embeddings v
WHERE v.embedding MATCH ? AND k = 50 ORDER BY v.distance;
```
**Страховка:** протокол `VectorIndex` с `SqliteVecIndex` (default) и `AccelerateBruteForceIndex`
(fallback если расширение не соберётся). Снимает главный техриск. Нужен SQLite с разрешённой загрузкой
расширений.

### 2.2 Эмбеддинги
| Модель | dim | Качество | Вес | Прогон |
|---|---|---|---|---|
| NLEmbedding.sentenceEmbedding (текущий) | ~512 | слабое, не cross-lingual | 0 (системная) | системный |
| **multilingual-e5-small / bge-small** via MLX/CoreML | 384 | SOTA retrieval, ru+en в одном пространстве | ~120МБ | MLX/ANE |
| bge-m3 | 1024 | лучшее, тяжелее | ~2ГБ | MLX |

**Рекомендация: multilingual-e5-small (384-dim) через MLX** (тот же стек, что Whisper turbo).
Решает боль «ищу „ошибки компиляции swift“ → на экране „build failed“». Сменный протокол:
```swift
protocol EmbeddingBackend: Sendable {
    var identifier: String { get }; var dimension: Int { get }
    func embed(_ text: String) async throws -> [Float]           // L2-normalized
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}
```
Все L2-норм → косинус = dot product. Модель фиксируется в `embeddings.model`+`dim` (для
переиндексации).

### 2.3 Гибридный поиск + ранжирование
1. Lexical: `text_fts MATCH` → top-100 с `bm25(text_fts)`.
2. Semantic: эмбеддинг запроса → `vec_embeddings MATCH` → top-100 с distance.
3. **Fusion (RRF):** `score = Σ 1/(k + rank_i)`, k≈60. Не требует калибровки шкал (bm25 vs косинус в
   разных единицах).
4. Фильтры (app/window/time/source) как WHERE к финальному набору id.
5. Режимы `mode = fts | semantic | hybrid` (default hybrid).
Возвращаем: timestamp, app, window, snippet (FTS `snippet()`), media path, score, какой leg сработал.

## 3. Retention / авто-очистка
```
retentionDays: Int?; maxStorageGB: Double?; pruneIntervalMinutes: Int; storageDirectoryBookmark: Data
```
**actor RetentionManager** (таймер раз в N мин + по триггеру «диск > порог»):
1. По времени: `cutoff = now - retentionDays`.
2. По размеру: FIFO по `ts` пока не уложимся (хранить `bytes` в строках — точнее, чем `du`).
3. Каскад: `ON DELETE CASCADE` → text_blocks → триггеры чистят FTS. **vec0 — явный `DELETE`** (FK не
   цепляется к виртуальной).
4. Файлы: собрать `relative_path`, удалить HEIC/audio (вне транзакции БД).
5. Батчами (`LIMIT 500`) в отдельных транзакциях (не держать длинный writer-лок).
6. Orphan-sweep: файлы без записи — удалять.
7. После крупного прунинга: FTS `optimize` + `PRAGMA wal_checkpoint(TRUNCATE)`.
```swift
actor RetentionManager {
    func runPrune(reason: PruneReason) async throws -> PruneReport
    func enforceTimeLimit(_ days: Int) async throws -> Int
    func enforceSizeLimit(_ maxBytes: Int64) async throws -> Int
    func sweepOrphans() async throws -> Int
    func currentStorageBytes() async throws -> Int64
}
```
**Релокация:** путь как **security-scoped bookmark** (Data), не строка (иначе sandbox потеряет доступ).
`StorageManager.relocate(to:)`: валидировать → пауза записи → переместить файлы (`relative_path` не
меняется — хранятся только имена) → обновить bookmark → возобновить. БД оставить в Application Support.

## 4. Чистый REST API

### 4.1 Сервер: FlyingFox vs Hummingbird 2 vs Vapor
| | FlyingFox | Hummingbird 2 | Vapor |
|---|---|---|---|
| Транзит. зависимости | swift-nio | NIO+ServiceLifecycle | большой стек |
| Вес | лёгкий | средний | тяжёлый |
| Роутинг | примитивный closure | typed+middleware | максимальный |
| Для menubar-app | да (встроен) | да | оверкилл |

**Рекомендация: остаться на FlyingFox** (0.26.2 уже собран, минимален, async, SSE). Hummingbird 2 —
альтернатива если позже нужен typed-routing. Vapor отвергнуть. Чинить: Codable вместо строк,
middleware ошибок, порт-поиск.

### 4.2 Конвенции
- Префикс `/v1/`. Bind только `127.0.0.1`. Ответы JSON UTF-8 (кроме media/frames).
- Время = ISO-8601 + epoch ms (оба). Единый формат ошибки `{ "error": { "code", "message", "details" } }`.
- Опц. `localToken` (`Authorization: Bearer`) для мутаций.

### 4.3 Эндпоинты (ключевые схемы)
- **`GET /v1/health`** → `{ status, version, uptimeSec, capturing, mcp:{http,stdio}, port }`
- **`GET /v1/search`** params: `q`(req), `mode`(fts|semantic|hybrid), `app`, `window`, `source`,
  `from/to`, `limit`(≤200), `offset` →
  ```json
  { "query":"…","mode":"hybrid","total":37,"results":[
    {"kind":"screen","id":90213,"ts":…,"tsISO":"…","app":{"bundleId":"…","name":"Xcode"},
     "windowTitle":"…","browserUrl":null,"snippet":"…<b>build failed</b>…","score":0.84,
     "matchedBy":["fts","semantic"],"media":{"frameUrl":"/v1/frames/90213","thumbUrl":"…?thumb=1"}},
    {"kind":"audio","id":4521,"ts":…,"snippet":"…","score":0.61,"matchedBy":["semantic"],
     "media":{"audioUrl":"/v1/media/audio_….m4a"},"transcript":{"language":"ru","speaker":null}}]}
  ```
- **`GET /v1/timeline`** (скруббер) params `from`,`to`(req),`bucket`(minute|5min|hour),`app` →
  `{ from,to,bucket,"buckets":[{ts,frameCount,audioSec,topApp,representativeFrameId}] }`
- **`GET /v1/frames/{id}`** — HEIC; `?thumb=1` (ресайз CoreImage, кешировать); `?format=jpeg`. Защита:
  числовой id → resolve `relative_path` из БД (не путь из URL).
- **`GET /v1/media/{filename}`** — стриминг с HTTP Range (206). Traversal защита обязательна.
- **`GET /v1/frames/{id}/context`** — ±N сек вокруг кадра (соседние кадры, апп, фрагменты транскрипции).
- **`POST /v1/capture/toggle`** (auth) → `{ capturing, permissions:{screen,mic,accessibility} }`
- **`GET/PUT /v1/settings/storage`** (auth) — путь/retention/usage.
- **`GET /v1/stats`** — frames/audio/transcriptions/embeddings/apps/oldest/newest/dbBytes/mediaBytes/
  transcription queue.

### 4.4 DTO (Codable) — `SlishuAPIDTO.swift`, никакого `[String:Any]`/ручных строк.

### 4.5 Path traversal (укрепление)
Текущий `hasPrefix(mediaDir.path)` уязвим (`/media-evil`). Правильно:
```swift
let base = mediaDir.standardizedFileURL.resolvingSymlinksInPath()
let target = base.appendingPathComponent(filename).standardizedFileURL.resolvingSymlinksInPath()
guard Array(target.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents else { return .forbidden }
```
Плюс для `/frames/{id}` — только числовой id→lookup (traversal by design невозможен). `/media/{filename}`
валидировать regex `^[A-Za-z0-9._-]+$`.

### 4.6 Динамический порт (фикс бага)
```swift
func startServer(preferred: [UInt16]) async throws -> UInt16 {
    for port in preferred {                          // [8088, 11435, 0]
        let server = HTTPServer(address: .loopback(port: port))
        do { try await server.start()                // бросит на bind ДО self
             self.server = server
             self.activePort = await server.listeningPort; return self.activePort
        } catch let e as SocketError where e.isAddrInUse { continue }   // только EADDRINUSE
        catch { throw error }                        // прочие — наверх
    }
    throw ServerError.noAvailablePort
}
```
Дефолт **не 8080** (конфликт с дев-серверами/IPFS). Писать активный порт в
`~/Library/Application Support/Slishu/port` (для MCP-обёртки/клиентов). `SlishuHTTPServer` — actor.

## 5. MCP сервер

### 5.1 Транспорт: stdio + HTTP/SSE (оба)
1. **stdio** (главный для desktop): `Slishu --mcp` (без UI, без HTTP, по stdin/stdout — канон для Claude
   Desktop/Cursor). stdio-процесс читает БД напрямую для запросов, мутации (toggle) проксирует в
   основной инстанс через `/v1/capture/toggle` (порт из port-файла); если не запущен — внятная ошибка.
2. **HTTP/SSE** на том же порту: `GET /mcp` (SSE) + `POST /mcp` (JSON-RPC). eventsource уже в
   зависимостях.

### 5.2 Официальный SDK vs ручной JSON-RPC
**Рекомендация: официальный `modelcontextprotocol/swift-sdk`** (уже в Package.resolved). Убирает
ручную сериализацию (`try!` краш), корректный handshake/lifecycle, оба транспорта, типизированные
`Tool`/`CallTool.Result`/`Content`. Запинить на тэг/ревизию (не `branch: main`).

### 5.3 Tools (тонкие обёртки над общим сервисным слоем)
- `search_history` `{ query, mode?, app?, from?, to?, limit? }` → форматированные хиты.
- `get_timeline` `{ from, to, bucket? }` → агрегированная активность.
- `get_context_at` `{ time }` → активный апп, окно, текст экрана, фрагменты разговора ±N сек + frame ref.
- `get_status` → запись, движок, размеры, права TCC.
- `toggle_recording` `{ enable }` → проксируется в основной инстанс.
Опционально MCP resources: кадры как `slishu://frame/{id}`.

### 5.4 Безопасная сериализация
Убрать все `try!`. Ответы через типы SDK. Любой throw в handler → MCP error result (`isError:true`),
не краш.
```swift
actor SlishuMCPServer {
    init(searchService:…, timeline:…, capture:…, transcription:…)
    func runStdio() async throws
    func attachHTTP(to server: SlishuHTTPServer) async
    private func registerTools() -> [MCPToolDefinition]
}
```

## 6. Транскрипция

### 6.1 Протокол
```swift
struct TranscriptionRequest: Sendable { let audioURL: URL; let languageHint: TranscriptionLanguage; let timestamp: Date }
struct TranscriptionSegment: Sendable { let text: String; let startOffset, endOffset: TimeInterval; let language: String; let speaker: String? }
struct TranscriptionResult: Sendable { let segments: [TranscriptionSegment]; let detectedLanguage: String; let engine: String }
enum TranscriptionProgress: Sendable { case loadingModel; case processing(fraction: Double); case finished }
protocol TranscriptionBackend: Sendable {
    var identifier: String { get }; var isAvailable: Bool { get async }
    func warmUp() async throws
    func transcribe(_ req: TranscriptionRequest, progress: @Sendable (TranscriptionProgress)->Void) async throws -> TranscriptionResult
}
```
Отмена через `withTaskCancellationHandler` + `Task.checkCancellation()` между чанками.

### 6.2 Реализации
- **MLXWhisperBackend (default)** — `mlx-whisper-v3-turbo`. MLX Swift (`ml-explore/mlx-swift` +
  examples). `warmUp()` грузит веса в GPU ОДИН раз (не на каждый чанк). decode m4a→PCM 16k mono
  (`AVAudioConverter`), чанки 30с (Whisper нативно на 30с-окнах — наши чанки уже 30с), сегменты с
  таймкодами. Язык auto/ru/en.
- **SFSpeechBackend** — обёртка над текущим (нулевой вес, слабее на ru/длинном).
- **WhisperCppBackend** — `whisper.cpp` (GGUF), альтернатива MLX.
- **CloudBackend** — opt-in, помечен (нарушает «локально»).

### 6.3 Очередь/запись
```swift
actor TranscriptionService {
    private var backend: TranscriptionBackend; private var queue: [TranscriptionJob]; private var current: Task<Void,Never>?
    func setBackend(_ id: TranscriptionEngineID) async
    func enqueue(audioURL: URL, audioCaptureId: Int64, timestamp: Date)
    func cancelAll(); var status: TranscriptionStatus { get }
}
```
Поток: взять `audio_id` → `backend.transcribe` → на каждый сегмент `INSERT INTO transcriptions`
(триггер сам в `transcription_fts`) → эмбеддинг агрегата → `embeddings`+`vec_embeddings` (в той же
сервисной очереди, НЕ `Task.detached`). Backpressure: лимит очереди (50).

### 6.4 Переключение
UserDefaults: `transcriptionEngine`, `transcriptionLanguage`, `embeddingModel`. Смена движка →
`setBackend` (отменяет текущий, warmUp нового). Старые транскрипции остаются (`engine` фиксирует чем).
Смена модели эмбеддингов → опция «переиндексировать».

### 6.5 Контракт приёма от capture-слоя
```swift
struct ScreenCaptureRecord: Sendable {
    let timestamp: Date; let bundleId, appName: String; let windowTitle, browserURL: String?
    let monitorId: String; let imageData: ImagePayload; let textBlocks: [CapturedTextBlock]
    let pixelWidth, pixelHeight: Int }
struct CapturedTextBlock: Sendable { let source: TextBlock.Source; let text: String; let confidence: Double; let bbox: CGRect? }
enum ImagePayload: Sendable { case heicData(Data); case fileWritten(relativePath: String) }
struct AudioCaptureRecord: Sendable { let timestamp: Date; let relativePath: String; let durationSec: Double; let channel: AudioCapture.Channel }
actor IngestService {                              // ЕДИНСТВЕННЫЙ writer
    func ingest(_ r: ScreenCaptureRecord) async throws -> Int64
    func ingest(_ r: AudioCaptureRecord) async throws -> Int64    // ставит на транскрипцию
}
```
`IngestService`: файл (если imageData) + `screen_captures`+`text_blocks` (триггеры → FTS) + embed; для
аудио → `TranscriptionService`. Один actor = один writer (нет гонок). Дедуп/blacklist/smart-pause
остаются на capture-слое.

## 7. Сводка типов
```
StorageManager (class) · SlishuDatabase (final) · IngestService (actor) ·
EmbeddingBackend → MLXEmbeddingBackend(me5-small,default)/NLEmbeddingBackend/BGE ·
VectorIndex → SqliteVecIndex(default)/AccelerateBruteForceIndex ·
SearchService (actor) · TimelineService (actor) · CaptureController (actor) · RetentionManager (actor) ·
TranscriptionBackend → MLXWhisper(default)/SFSpeech/WhisperCpp/Cloud · TranscriptionService (actor) ·
SlishuHTTPServer (actor) · SlishuMCPServer (actor) · SlishuAPIDTO (Codable)
```

## 8. Зависимости и вес
| Зависимость | Назначение | Вес |
|---|---|---|
| GRDB 6.29 (есть) | SQLite/FTS5/pool | лёгкая |
| sqlite-vec (добавить) | вектор KNN | очень лёгкая (один C-файл) |
| FlyingFox 0.26 (есть) | REST+SSE | лёгкая (NIO транзит.) |
| MCP swift-sdk (есть, запинить) | MCP stdio+SSE | средняя |
| mlx-swift + examples (добавить) | Whisper turbo + e5 | рантайм лёгкий, веса ~1.5ГБ (не в бандле) |
| Apple frameworks | NL/Speech/AVF/Accelerate/Vision/SCK | 0 |
Net: ядро лёгкое. Тяжесть только в ML-весах (по требованию). На слабой машине дефолт может стартовать
на SFSpeech+NLEmbedding (нулевой вес).

## 9. Порядок реализации
1. Схема+миграции v1 (FTS-триггеры, PRAGMA). 2. **sqlite-vec интеграция** + VectorIndex fallback
(проверить рано — главный риск). 3. IngestService + EmbeddingBackend (NLEmbedding→MLX e5).
4. SearchService (FTS→vec→RRF)+DTO. 5. REST (фикс порта, эндпоинты, traversal). 6. TranscriptionBackend
(SFSpeech→MLXWhisper). 7. MCP (SDK, stdio+SSE). 8. RetentionManager. 9. MLX e5 + переиндексация.

## Риски
- sqlite-vec под Swift 6 toolchain — проверить загрузку рано; Accelerate fallback. - MLX Whisper:
модель в actor, не перезагружать на чанк, отмена. - Security-scoped bookmark (plain string сломается).
- Единый writer (убрать Task.detached). - MCP SDK запинить ревизию.
