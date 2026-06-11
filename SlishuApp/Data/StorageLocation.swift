import Foundation

/// Единый источник пути к данным ZBS Eye для ВСЕХ процессов (GUI, --mcp, --import-screenpipe,
/// --backup-now) и всех модулей. Раньше путь выводился НЕЗАВИСИМО в 6 местах — relocate был бы
/// невозможен (вспомогательные процессы читали бы старое место). Теперь relocate меняет ТОЛЬКО
/// UserDefaults, и при следующем старте все процессы читают новый root.
///
/// Не-sandbox приложение: security-scoped bookmark не требуется (полный доступ к $HOME), но обычный
/// bookmark переживает переименование/перемонтирование тома (внешний SSD под другим /Volumes/...),
/// чего голый путь не умеет. Поэтому храним и bookmark, и path — bookmark главнее.
enum StorageLocation {
    private static let bookmarkKey = "slishu.dataRoot.bookmark"
    private static let pathKey = "slishu.dataRoot.path"

    /// Корень данных. Приоритет: bookmark → path → legacy ~/Library/Application Support/ZBS Eye.
    static func dataRoot() -> URL {
        let url = resolveConfiguredRoot() ?? legacyRoot()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func databaseURL() -> URL { dataRoot().appendingPathComponent("slishu.sqlite") }

    static func mediaDirectory() -> URL {
        let dir = dataRoot().appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func portURL() -> URL { dataRoot().appendingPathComponent("port") }
    static func serverLogURL() -> URL { dataRoot().appendingPathComponent("server.log") }

    /// Дефолтное (legacy) расположение — то же, что было хардкодом до relocate.
    static func legacyRoot() -> URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("ZBS Eye", isDirectory: true)
    }

    /// ОДНОРАЗОВАЯ миграция при ребрендинге Slishu → ZBS Eye. Bundle id сменился (gg.zbs.eye) → новый
    /// дефолтный root «ZBS Eye» пуст, а 50k кадров лежат в старой «Slishu». Если новая папка ещё без
    /// базы, а старая — с базой, переносим (move в пределах тома — атомарно/мгновенно). Вызывать ПЕРВЫМ
    /// в SlishuMain (до открытия БД любым процессом: GUI/--mcp/--backup-now). Relocate (bookmark) не трогаем.
    static func migrateFromLegacyNameIfNeeded() {
        let fm = FileManager.default
        guard UserDefaults.standard.data(forKey: bookmarkKey) == nil,
              UserDefaults.standard.string(forKey: pathKey) == nil else { return }   // relocated → данные не в legacy
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let newRoot = support.appendingPathComponent("ZBS Eye", isDirectory: true)
        let oldRoot = support.appendingPathComponent("Slishu", isDirectory: true)
        guard !fm.fileExists(atPath: newRoot.appendingPathComponent("slishu.sqlite").path),
              fm.fileExists(atPath: oldRoot.appendingPathComponent("slishu.sqlite").path) else { return }
        if !fm.fileExists(atPath: newRoot.path) {
            try? fm.moveItem(at: oldRoot, to: newRoot)            // атомарный rename всей папки
        } else {
            for item in (try? fm.contentsOfDirectory(at: oldRoot, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.moveItem(at: item, to: newRoot.appendingPathComponent(item.lastPathComponent))
            }
        }
    }

    /// Сконфигурирован ли НЕ-дефолтный root (для UI «перенести обратно»).
    static func isRelocated() -> Bool {
        resolveConfiguredRoot() != nil
    }

    /// АНТИ-SPLIT-BRAIN: relocate был настроен, но целевой том сейчас недоступен (внешний SSD отключён).
    /// Возвращает сконфигурированный путь — bootstrap по нему ОТКАЗЫВАЕТСЯ стартовать на legacy «с нуля»
    /// (иначе пользователь увидел бы пустую историю, а новые кадры легли бы в раскол). nil = всё ок.
    static func unavailableConfiguredPath() -> String? {
        let d = UserDefaults.standard
        let configured = d.data(forKey: bookmarkKey) != nil || d.string(forKey: pathKey) != nil
        guard configured, resolveConfiguredRoot() == nil else { return nil }
        return d.string(forKey: pathKey) ?? "(внешний том)"
    }

    /// Сохранить новый root (ПОСЛЕ успешной миграции). Записывает bookmark + path.
    static func setRoot(_ url: URL) {
        let d = UserDefaults.standard
        if let data = try? url.bookmarkData() { d.set(data, forKey: bookmarkKey) }
        d.set(url.path, forKey: pathKey)
    }

    /// Сбросить на legacy (перенос обратно в Application Support).
    static func resetToLegacy() {
        let d = UserDefaults.standard
        d.removeObject(forKey: bookmarkKey)
        d.removeObject(forKey: pathKey)
    }

    /// Читаемый путь текущего root (для Settings).
    static func displayPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = dataRoot().path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private static func resolveConfiguredRoot() -> URL? {
        let d = UserDefaults.standard
        if let data = d.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                if stale, let fresh = try? url.bookmarkData() { d.set(fresh, forKey: bookmarkKey) }
                return url
            }
        }
        if let path = d.string(forKey: pathKey), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil   // bookmark/path заданы, но недоступны (том отключён) → НЕ молчим на legacy: см. dataRoot fallback
    }
}
