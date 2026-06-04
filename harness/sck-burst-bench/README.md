# SCK burst benchmark (Slishu — blocking harness 1b)

**Зачем.** В плане выбран event-driven захват через `SCScreenshotManager.captureSampleBuffer`
(on-demand single frame) вместо persistent `SCStream`. Pro предупредил: при burst (печать/скролл/
переключение окон, 2–6 захватов/с) повторный on-demand setup может проиграть warmed-stream, и план
это **не измерял**. Этот harness измеряет.

## Что мерит
- **on-demand cold / warm p50/p95** — латентность `SCScreenshotManager.captureImage` (первый вызов и
  серия). Отсюда «макс кадров/с on-demand».
- **stream startup** — время от `startCapture()` до первого кадра (накладные расхода warmed-stream).
- **stream steady fps** — сколько кадров/с реально отдаёт стрим.
- **burst dropped** — при запросе N fps за окно, сколько кадров стрим недодал.
- **энергия** — self-CPU% за фиксированное окно: on-demand polling vs stream (прокси энергии).
- **вердикт** — порог fps, где warmed-stream начинает бить on-demand.

## Запуск
```
cd harness/sck-burst-bench
swift build -c release
./.build/release/SckBurstBench > ~/ai/slishu/workspace/sck-bench.json
```
Первый запуск попросит **Screen Recording** (System Settings → Privacy → Screen Recording → разреши
Терминалу), затем перезапусти. Прогон ~40–50с.

Аргументы: `--warm-count` (30), `--energy-sec` (15), `--burst-sec` (2), `--fps` (60).

## Как читать
- Если **on-demand warm p50 ≤ ~15–20мс** → on-demand держит ~50–60 fps, persistent stream для
  event-driven (1 кадр/событие) — лишний оверхед. Тогда план v2 («on-demand + burst-stream только при
  ≥4 триггера/10с/видео») верен.
- Если **on-demand warm заметно дороже стрима** или **энергия on-demand при частых захватах >> stream**
  → порог входа в burst-stream надо снижать (warmed stream чаще).
- **stream startup** показывает цену «разогрева» — если >100мс, переключение в burst-stream должно быть
  с упреждением, а не реактивным.

Результаты → `workspace/sck-bench.json` + фиксируются в `workspace/PLAN.md`.
