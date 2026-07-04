---
name: eye-db-validate
description: Validate any SQL change (migrations, triggers, queue logic, FTS) on a throwaway scratch database with sqlite3 before it ships — with a worked example on the embed queue (dedup, AFTER DELETE triggers, ordering). Use before committing anything that touches ZBSEyeDatabase or raw SQL.
---

# eye-db-validate — prove SQL on a scratch DB, never on the user's data

The user's DB is their history — irreplaceable, and owned by a single writer (the GUI). So every
migration, trigger, and queue query gets proven on a **throwaway DB with plain `sqlite3`** first.
This catches wrong trigger semantics, dedup violations, and ordering bugs in seconds, with zero risk,
and without launching the app (which would be a TCC violation anyway — see CLAUDE.md).

## The pattern

1. Create a scratch DB in a temp dir.
2. Apply the *real* DDL — copy it verbatim from `ZBSEyeApp/Data/ZBSEyeDatabase.swift` (the migration
   you're adding or changing), don't retype it from memory.
3. Feed it hostile fixtures: duplicates, deletes, empty tables, out-of-order timestamps.
4. Assert exact expected outputs. A mismatch = the SQL is wrong, fix before shipping.
5. Delete the temp dir.

## Worked example — validating the embed queue

The real schema (migration `v6_embed_queue`): a durable queue of rows awaiting semantic embedding,
deduped by `(row_id, kind)`, drained newest-first, and cleaned up by `AFTER DELETE` triggers on the
parent tables.

```bash
TMP="$(mktemp -d)"; DB="$TMP/scratch.sqlite"

sqlite3 "$DB" <<'SQL'
-- minimal parents (only the columns the triggers touch)
CREATE TABLE screen_captures (id INTEGER PRIMARY KEY, ts INTEGER NOT NULL);
CREATE TABLE transcriptions  (id INTEGER PRIMARY KEY, ts INTEGER NOT NULL);

-- DDL copied from ZBSEyeDatabase.swift, migration v6_embed_queue
CREATE TABLE embed_queue (
    row_id   INTEGER NOT NULL,    -- screen_captures.id or transcriptions.id
    kind     INTEGER NOT NULL,    -- 0 = screen frame, 1 = transcript
    ts       INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (row_id, kind)
) WITHOUT ROWID;
CREATE INDEX idx_embed_queue_ts ON embed_queue(ts DESC);
CREATE TRIGGER embed_queue_screen_ad AFTER DELETE ON screen_captures BEGIN
    DELETE FROM embed_queue WHERE row_id = old.id AND kind = 0;
END;
CREATE TRIGGER embed_queue_transcript_ad AFTER DELETE ON transcriptions BEGIN
    DELETE FROM embed_queue WHERE row_id = old.id AND kind = 1;
END;
SQL

echo "— test 1: dedup — re-enqueueing the same row must be a no-op"
sqlite3 "$DB" "
INSERT INTO screen_captures(id, ts) VALUES (1, 100), (2, 200);
INSERT OR IGNORE INTO embed_queue(row_id, kind, ts) VALUES (1, 0, 100);
INSERT OR IGNORE INTO embed_queue(row_id, kind, ts) VALUES (1, 0, 100);  -- duplicate
INSERT OR IGNORE INTO embed_queue(row_id, kind, ts) VALUES (2, 0, 200);
SELECT COUNT(*) FROM embed_queue;"
# EXPECT: 2  (not 3 — dedup held)

echo "— test 2: same row_id, different kind must coexist (PK is composite)"
sqlite3 "$DB" "
INSERT INTO transcriptions(id, ts) VALUES (1, 150);
INSERT OR IGNORE INTO embed_queue(row_id, kind, ts) VALUES (1, 1, 150);
SELECT COUNT(*) FROM embed_queue;"
# EXPECT: 3

echo "— test 3: AFTER DELETE trigger cleans ONLY the matching kind"
sqlite3 "$DB" "
DELETE FROM screen_captures WHERE id = 1;
SELECT row_id, kind FROM embed_queue ORDER BY kind, row_id;"
# EXPECT: 2|0 and 1|1  (frame #1 gone from the queue; transcript #1 survives)

echo "— test 4: drain order is newest-first, and retried rows sink out"
sqlite3 "$DB" "
UPDATE embed_queue SET attempts = 3 WHERE row_id = 2 AND kind = 0;
SELECT row_id, kind FROM embed_queue WHERE attempts < 3 ORDER BY ts DESC LIMIT 10;"
# EXPECT: only 1|1  (row 2 exceeded attempts → out of rotation, but NOT deleted)

rm -rf "$TMP"
```

Run it, compare every `EXPECT` against the actual output. Any drift = stop and fix the SQL.

## Adapting the pattern

- **New migration** → build the scratch DB with all *prior* migrations' DDL, then apply yours; assert
  the schema (`.schema table`) and that existing fixture rows survive (migrations must never erase —
  repo invariant).
- **FTS5 external-content** (repo gotcha): compute `snippet()`/`bm25()` in a subquery purely over the
  FTS table (`WITH hits AS (SELECT ... FROM text_fts WHERE text_fts MATCH ... LIMIT n) SELECT ...`);
  joining first breaks the FTS context. Assert your query returns snippets on scratch fixtures.
- **Retention / pruning** → fixture rows on both sides of the cutoff; assert `prune(0)` deletes
  nothing ("0 = forever" is a repo invariant, not "older than 0 days").

Ship the SQL only after the scratch run is green; then build via `eye-build` and review via
`eye-review-loop`.
