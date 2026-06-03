import Foundation

// Результат пробы одного приложения. Поля соответствуют JSON-матрице из ревью Pro.
struct AppProbeResult: Codable {
    var bundleId: String
    var appName: String
    var appVersion: String?
    var electronVersion: String?
    var isElectron: Bool
    var pid: Int32
    var frontmost: Bool

    // Возврат-коды установки флагов
    var manualSetError: String      // success | attributeUnsupported | cannotComplete | notImplemented | apiDisabled | ...
    var enhancedSetError: String    // тот же набор, либо "skipped" в conservative-режиме

    // Состояние дерева
    var preFlagsChildren: Int       // сколько детей у app-элемента ДО установки флагов
    var preFlagsTextChars: Int      // сколько текста извлеклось ДО флагов (быстрый проход)
    var firstNonEmptyMs: Int?       // через сколько мс после флагов дерево стало непустым (nodeCount>1)
    var firstUsefulTextMs: Int?     // через сколько мс набралось >= usefulTextThreshold символов

    // Финальный обход
    var nodeCount: Int
    var textCharCount: Int          // ВЕСЬ текст (контент + chrome) — оптимистичная метрика
    var contentChars: Int           // текст из content-ролей (TextArea/TextField/WebArea/длинный StaticText)
    var chromeChars: Int            // текст из chrome-ролей (Button/MenuItem/короткий StaticText)
    var focusedTextChars: Int
    var webAreaFound: Bool
    var urlFound: Bool
    var url: String?
    var windowTitle: String?
    var textSample: String          // первые ~700 симв. КОНТЕНТ-текста (content-роли) — глазами проверить
    var rawSample: String           // первые ~700 симв. ЛЮБОГО текста дерева — увидеть что есть даже если classifier пропустил

    // CPU target-приложения (грубо, через proc_pid_rusage delta)
    var cpuBeforePct: Double?
    var cpuAfterPct: Double?
    var cpuDeltaTargetApp: Double?

    // Классификация и тайминги обхода
    var quality: String             // none | titleOnly | partialUseful | fullUseful | timedOut | sickPID
    var budgetMs: Int
    var traversalMs: Int
    var retriesUsed: Int
    var notes: [String]
}

struct HostInfo: Codable {
    var macOS: String
    var voiceOverRunning: Bool
    var windowManagers: [String]
    var otherAXConsumers: [String]  // запущенные AX-инструменты, которые могли глобально поднять accessibility
    var harnessVersion: String
    var mode: String                // conservative | aggressive
}

struct RunOutput: Codable {
    var generatedAtUnixMs: Int64
    var host: HostInfo
    var results: [AppProbeResult]
}
