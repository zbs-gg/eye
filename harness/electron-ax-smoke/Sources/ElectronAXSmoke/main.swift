import Foundation
import AppKit
import ApplicationServices

let harnessVersion = "1.0.0"

// ── парсинг аргументов ──────────────────────────────────────────────────────
var mode: ProbeMode = .conservative
var appFilter: [String] = []          // подстроки bundleId/имени
var frontmostOnly = false
var electronOnly = false
var outPath: String?

var it = CommandLine.arguments.dropFirst().makeIterator()
while let arg = it.next() {
    switch arg {
    case "--mode":
        if let v = it.next(), let m = ProbeMode(rawValue: v) { mode = m }
    case "--apps":
        if let v = it.next() { appFilter = v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
    case "--frontmost": frontmostOnly = true
    case "--electron-only": electronOnly = true
    case "--out": outPath = it.next()
    case "-h", "--help":
        FileHandle.standardError.write("""
        Electron AX Smoke Harness — мерит useful-AX на запущенных приложениях.

        Использование:
          electron-ax-smoke [--mode conservative|aggressive] [--apps vscode,slack,obsidian]
                            [--frontmost] [--electron-only] [--out result.json]

          --mode         conservative (по умолчанию): AXManualAccessibility, Enhanced добивается
                         только при слабом результате. aggressive: оба флага сразу.
          --apps         фильтр по подстроке bundleId/имени (через запятую).
          --frontmost    пробовать только активное приложение (лучше для focused-editor текста).
          --electron-only пробовать только Electron-приложения.
          --out          путь для JSON (по умолчанию stdout).

        ВАЖНО: нужно разрешение Accessibility для процесса, который запускает бинарь
        (обычно Терминал/iTerm). System Settings → Privacy & Security → Accessibility.

        Совет: прогони несколько раз с разными активными окнами (пустое окно / большой
        документ / выделенный текст / веб-страница), чтобы покрыть режимы из матрицы Pro.

        """.data(using: .utf8)!)
        exit(0)
    default:
        FileHandle.standardError.write("Неизвестный аргумент: \(arg)\n".data(using: .utf8)!)
    }
}

// ── проверка Accessibility-прав ──────────────────────────────────────────────
let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
)
if !trusted {
    FileHandle.standardError.write("""
    ⚠️  Нет Accessibility-прав. Появился системный диалог — выдай доступ процессу,
       который запускает бинарь (Терминал/iTerm), затем перезапусти.
       System Settings → Privacy & Security → Accessibility.

    """.data(using: .utf8)!)
    exit(1)
}

// ── сбор приложений ──────────────────────────────────────────────────────────
func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let selfPID = ProcessInfo.processInfo.processIdentifier
var apps: [NSRunningApplication]

if frontmostOnly {
    apps = NSWorkspace.shared.frontmostApplication.map { [$0] } ?? []
} else {
    apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.processIdentifier != selfPID && $0.bundleIdentifier != nil
    }
}

if !appFilter.isEmpty {
    apps = apps.filter { app in
        let hay = ((app.bundleIdentifier ?? "") + " " + (app.localizedName ?? "")).lowercased()
        return appFilter.contains { hay.contains($0.lowercased()) }
    }
}

if electronOnly {
    apps = apps.filter { SystemContext.electronInfo(bundleURL: $0.bundleURL).isElectron }
}

// Electron сначала, потом по имени
apps.sort { a, b in
    let ea = SystemContext.electronInfo(bundleURL: a.bundleURL).isElectron
    let eb = SystemContext.electronInfo(bundleURL: b.bundleURL).isElectron
    if ea != eb { return ea && !eb }
    return (a.localizedName ?? "") < (b.localizedName ?? "")
}

if apps.isEmpty {
    eprint("Нет подходящих приложений для пробы. Открой VS Code / Obsidian / Slack / Chrome и повтори.")
    exit(1)
}

// ── контекст хоста ───────────────────────────────────────────────────────────
let consumers = SystemContext.detectAXConsumers()
let host = HostInfo(
    macOS: SystemContext.macOSVersionString(),
    voiceOverRunning: SystemContext.isVoiceOverRunning(),
    windowManagers: SystemContext.detectWindowManagers(),
    otherAXConsumers: consumers,
    harnessVersion: harnessVersion,
    mode: mode.rawValue
)

eprint("ZBSEye Electron AX Smoke — macOS \(host.macOS), mode=\(mode.rawValue), VoiceOver=\(host.voiceOverRunning), WM=\(host.windowManagers.joined(separator: ",").isEmpty ? "none" : host.windowManagers.joined(separator: ","))")
if host.voiceOverRunning {
    eprint("⚠️  VoiceOver активен — не перетягиваем режим; результаты могут отличаться от обычного использования.")
}
if !consumers.isEmpty {
    eprint("⚠️  ЗАГРЯЗНЕНИЕ: запущены AX-инструменты [\(consumers.joined(separator: ", "))] — они могли")
    eprint("    глобально включить accessibility. «Дерево доступно без флага» может быть НЕ нашей заслугой.")
    eprint("    Для честного «холодного» замера закрой их и перепрогони.")
}
eprint("Приложений к пробе: \(apps.count). Каждая проба ~4–5с (ретраи 250/750/1500/3000мс).\n")

// ── прогон ───────────────────────────────────────────────────────────────────
var results: [AppProbeResult] = []
for (idx, app) in apps.enumerated() {
    let name = app.localizedName ?? app.bundleIdentifier ?? "?"
    eprint("[\(idx + 1)/\(apps.count)] \(name) …")
    let r = AXProbe.probe(app: app, mode: mode)
    results.append(r)
    let cpu = r.cpuDeltaTargetApp.map { String(format: "%+.1f%%", $0) } ?? "?"
    let firstUseful = r.firstUsefulTextMs.map { "\($0)ms" } ?? "—"
    eprint(String(format: "    electron=%@ manual=%@ quality=%@ content=%d chrome=%d pre=%d focused=%d url=%@ firstUseful=%@ cpuΔ=%@",
                  r.isElectron ? "yes" : "no", r.manualSetError,
                  r.quality, r.contentChars, r.chromeChars, r.preFlagsTextChars, r.focusedTextChars,
                  r.urlFound ? "yes" : "no", firstUseful, cpu))
}

// ── вывод ────────────────────────────────────────────────────────────────────
let output = RunOutput(
    generatedAtUnixMs: Int64(Date().timeIntervalSince1970 * 1000),
    host: host,
    results: results
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let data = (try? encoder.encode(output)) ?? Data()

if let outPath {
    try? data.write(to: URL(fileURLWithPath: outPath))
    eprint("\n✅ JSON записан: \(outPath)")
} else {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

// краткая сводка по Electron в stderr
let electron = results.filter { $0.isElectron }
if !electron.isEmpty {
    eprint("\n── Сводка по Electron (\(electron.count)) ── (content = реальный текст, chrome = кнопки/меню)")
    for r in electron {
        eprint(String(format: "  %-22@ quality=%-13@ content=%-6d chrome=%-6d manual=%@",
                      r.appName as NSString, r.quality as NSString, r.contentChars, r.chromeChars, r.manualSetError))
        if !r.textSample.isEmpty {
            let firstLine = r.textSample.split(separator: "\n").first.map(String.init) ?? ""
            eprint("      ↳ content: \(firstLine.prefix(100))")
        } else if !r.rawSample.isEmpty {
            // контента ноль — но что вообще есть в дереве?
            let firstLine = r.rawSample.split(separator: "\n").first.map(String.init) ?? ""
            eprint("      ↳ raw(нет content): \(firstLine.prefix(100))")
        }
    }
    let good = electron.filter { $0.quality == "fullUseful" || $0.quality == "partialUseful" }.count
    eprint("\n  useful по КОНТЕНТУ (full/partial): \(good)/\(electron.count)")
    if !consumers.isEmpty {
        eprint("  ⚠️  но на машине активны AX-инструменты \(consumers) — для честного вывода нужен прогон без них.")
    }
    eprint("  Глянь textSample в JSON: это реальный контент или «File/Edit/Settings»-chrome?")
}
