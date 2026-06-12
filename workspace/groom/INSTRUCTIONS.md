# Roadmap grooming — операционная инструкция (bi-daily)

Это манифест для автономного прогона раз в ~2 дня. Запускается headless (`claude -p`) или вручную.
Цель: держать `workspace/ROADMAP.md` живым и грумленым с минимальным участием Ника, и выдавать ему
**короткий** дайджест «стоит сделать A/B/C — потому что X». Не отчёт на страницу — 5–8 строк.

## Контекст продукта (не забывать)
ZBS Eye (коднейм Slishu) — локальная «вечная память» Mac (экран+аудио, поиск, REST+MCP). **Главный
дифференциатор: 100% локально, без облака, без аккаунта, без подписки.** Конкурент-ориентир — screenpipe
(ушёл на подписку+облако). Любая рекомендация проверяется вопросом: усиливает ли это нишу «твоя память —
твоя, локально»? Если фича тянет в облако/подписку без причины — это НЕ наш путь (см. «declined»).

## Что прочитать каждый прогон (порядок)
1. **Текущий бэклог** — `workspace/ROADMAP.md` (источник истины; его и грумим).
2. **Что сделано с прошлого раза** — `git -C /Users/nikshilov/ai/slishu log --since="3 days ago" --oneline`
   + project claude-mem (observation_search по «Eye/Slishu»). Закрытые items → пометить done.
3. **Как Ник реально юзает Eye** (read-only, не мутировать БД):
   `sqlite3 "$HOME/Library/Application Support/ZBS Eye/slishu.sqlite"` —
   топ-приложения за 2 дня (`SELECT a.name, COUNT(*) FROM screen_captures c JOIN apps a ON a.id=c.appId
   WHERE c.ts > <epoch_ms_2d_ago> AND c.monitorId<>'sp' GROUP BY a.name ORDER BY 2 DESC LIMIT 10`),
   объём живого захвата, есть ли аудио. Сигнал: что он делает = что приоритезировать (напр. много
   звонков → аудио-фичи; много кода → code-context). Если живого захвата ~0 — флаг «не пользуется,
   разобраться почему» важнее любой новой фичи.
4. **Чаты по Eye** — claude-mem observation_search: что Ник просил/ругал/хотел по Eye за 2 дня.
5. **Ландшафт конкурентов** — WebFetch screenpipe (task-mining, computer-use-agent-evals, pipes,
   compare/build-it-yourself, pricing) + WebSearch «Rewind.ai / Limitless / Microsoft Recall / Granola
   2026» на ИЗМЕНЕНИЯ с прошлого прогона. Новое у них → кандидат в watch/add.

## Как грумить
- Каждый item: `title · priority(P0/P1/P2) · why(1 строка) · evidence(usage/competitor/chat/git)`.
- Приоритет = (усиление ниши × сигнал из usage/чатов) / (стоимость × риск облака).
- Done items → в `## Готово` с датой. Stale (3 прогона без движения и без сигнала) → `## Заморожено`
  с причиной. Новое → в backlog с evidence.
- **Honest declined**: что НЕ делаем и почему — это стратегия, держать секцию `## Сознательно не делаем`.
- Не раздувать: backlog > 15 активных items — слить/срезать. Лучше 5 острых, чем 20 размытых.

## Выход
1. Перезаписать `workspace/ROADMAP.md` (грумленый).
2. Записать дайджест `workspace/groom/digest-YYYY-MM-DD.md` (полная версия с evidence).
3. **Короткий дайджест Нику** (5–8 строк, формат ниже) → доставка (Telegram/файл — см. `delivery`).
4. Закоммитить бэклог: `git add workspace/ROADMAP.md workspace/groom/ && git commit -m "roadmap groom YYYY-MM-DD"` (ветка `roadmap-groom`, не main; push опционально).

## Формат короткого дайджеста (то, что видит Ник)
```
🔭 ZBS Eye roadmap · <дата>
Сделать:
1. <A> — <почему, 1 строка> [evidence]
2. <B> — …
3. <C> — …
Конкуренты: <1 строка — что нового/важного>
Usage: <1 строка — что вижу по твоим захватам>
```
Кратко и по делу. Если за 2 дня НЕТ значимых изменений — так и написать одной строкой, не выдумывать.

## Бюджет / тон
Один прогон ≈ один claude-сессия с web+git+sqlite. Не запускать тяжёлые multi-agent workflow без нужды —
обычного прогона достаточно. Тон дайджеста — как коллега-сооснователь: честно, без хайпа, без «вау».
