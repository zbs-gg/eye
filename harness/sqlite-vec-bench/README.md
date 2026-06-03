# sqlite-vec scale benchmark (Slishu — blocking harness 1c)

**Зачем.** Pro усомнился в «sqlite-vec даёт 1M за десятки мс» (его данные: 1M×128D ≈33мс, но 192D
≈192мс, не проходит 100мс smoke). Этот harness меряет на **нашей размерности (384)** и **нашем
toolchain (Swift)** три вещи, которые Pro назвал рисками:
1. **Статическая линковка** sqlite-vec в Swift (важно для нотаризации — loadable extension под
   Hardened Runtime неприятен; static предпочтительнее).
2. **Реальная латентность KNN** на 100k–1M × 384, plain и с metadata-prefilter (ts/app).
3. **Размер БД на диске** (Pro: 3M×384×4 = ~4.6GB raw — «лёгкий рекордер пахнет data-warehouse»).

## Архитектура линковки (то, что проверяем)
- `sqlite-vec.c` компилируется с `-DSQLITE_CORE -DSQLITE_VEC_STATIC` → использует системный `sqlite3.h`
  (SDK), не extension API. Линкуется с Apple-подписанным `libsqlite3` (`-lsqlite3`).
- Swift вызывает `sqlite3_vec_init(db, &err, nil)` напрямую после открытия каждого соединения.
- Это **тот же путь, что пойдёт в продакшн** (GRDB умеет custom-SQLite; для нотаризации — статика).
- `CSqliteVec` (C-target) экспонирует и весь sqlite3 C API, и `sqlite3_vec_init` через `shim.h`.

## Запуск
```
cd harness/sqlite-vec-bench
swift build -c release
./.build/release/VecBench --sizes 100000,500000,1000000 --queries 100 > result.json
```
Аргументы: `--sizes` (через запятую), `--queries` (число запросов для p50/p95), `--dim` (384),
`--k` (10). JSON — в stdout, прогресс/сводка — в stderr.

## Что меряется
- **insertSec / rowsPerSec** — скорость ingest (важно для 24/7 writer).
- **plain p50/p95** — KNN без фильтра (brute-force по всем N).
- **ts-filter p50/p95** — KNN с `WHERE ts > cutoff` (последние ~10% — «недавнее окно»). Проверяет, prefilter
  это или filter-after-KNN.
- **app-filter p50/p95** — KNN с `WHERE app_id = ?` (1 из 50 приложений).
- **dbBytes** — размер БД на диске.

## Как читать (пороги Pro)
- ≤250k векторов — sqlite-vec exact ок дефолтом.
- 250k–1M — только с time/app prefilter или temporal shard.
- >1M — нужен ANN или time-windowed поиск.

Цель — найти, на каком N plain p95 пробивает 50/150мс, и **спасает ли prefilter** (temporal shard /
`ts>`/`app_id=`). Если prefilter ускоряет (а smoke показал, что да) — стратегия «default search last
7/30 days + expand» из плана v2 работает.

## Результаты прогона (2026-06-03, 384-dim, M-серия)
| N | plain p95 | ts-filter p95 | вставка | размер |
|---|---|---|---|---|
| 100k | 37ms ✅ | 24ms | 94k/с | 0.16GB |
| 500k | 180ms ❌ | 118ms | 99k/с | 0.79GB |
| 1M | 369ms ❌ | 240ms | 96k/с | 1.58GB |

- Static-линковка работает (sqlite-vec v0.1.9 + sqlite 3.51.0) → нотаризация ок.
- sqlite-vec exact годится до ~100–150k; дальше нужны **temporal shards** (поиск по месяцу/30 дням) +
  embed-on-change (не на каждый кадр). Размер критичен → retention 7д/20GB.
- Полный JSON — `workspace/vec-bench.json`. Зафиксировано в `workspace/PLAN.md`.
