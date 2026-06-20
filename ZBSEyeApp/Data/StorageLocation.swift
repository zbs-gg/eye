import Foundation

/// Единый источник пути к данным ZBS Eye для ВСЕХ процессов (GUI, --mcp, --import-history,
/// --backup-now) и всех модулей. Раньше путь выводился НЕЗАВИСИМО в 6 местах — relocate был бы
/// невозможен (вспомогательные процессы читали бы старое место). Теперь relocate меняет ТОЛЬКО
/// UserDefaults, и при следующем старте все процессы читают новый root.
///
/// Не-sandbox приложение: security-scoped bookmark не требуется (полный доступ к $HOME), но обычный
/// bookmark переживает переименование/перемонтирование тома (внешний SSD под другим /Volumes/...),
/// чего голый путь не умеет. Поэтому храним и bookmark, и path — bookmark главнее.
enum StorageLocation {
    private static let bookmarkKey = "zbseye.dataRoot.bookmark"
    private static let pathKey = "zbseye.dataRoot.path"

    /// Корень данных. Приоритет: bookmark → path → legacy ~/Library/Application Support/ZBS Eye.
    static func dataRoot() -> URL {
        let url = resolveConfiguredRoot() ?? legacyRoot()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func databaseURL() -> URL { dataRoot().appendingPathComponent("zbseye.sqlite") }

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

    /// ОДНОРАЗОВАЯ миграция ключей UserDefaults со старого кодового префикса на новый. Раньше все
    /// настройки и курсоры жили под префиксом старого коднейма; после ребрендинга кодовой базы код
    /// читает новый префикс. Копируем значения (включая dataRoot.bookmark/path — иначе relocate-том
    /// «потеряется»), затем убираем старые. Вызывать ПЕРВЫМ в main, ДО любого чтения настроек.
    static func migrateLegacyDefaultsIfNeeded() {
        let d = UserDefaults.standard
        let oldPrefix = "slishu."
        let newPrefix = "zbseye."
        for (key, value) in d.dictionaryRepresentation() where key.hasPrefix(oldPrefix) {
            let newKey = newPrefix + key.dropFirst(oldPrefix.count)
            if d.object(forKey: newKey) == nil { d.set(value, forKey: newKey) }
            d.removeObject(forKey: key)
        }
    }

    /// ОДНОРАЗОВАЯ миграция при ребрендинге: bundle id сменился (gg.zbs.eye) → дефолтный root «ZBS Eye».
    /// Если новая папка ещё без базы, а старая (под прежним именем продукта) — с базой, переносим
    /// (move в пределах тома — атомарно/мгновенно). Вызывать в main (до открытия БД любым процессом).
    /// Relocate (bookmark) не трогаем. ДО переименования файла базы (ищем по старому имени в старой папке).
    static func migrateFromLegacyNameIfNeeded() {
        let fm = FileManager.default
        guard UserDefaults.standard.data(forKey: bookmarkKey) == nil,
              UserDefaults.standard.string(forKey: pathKey) == nil else { return }   // relocated → данные не в legacy
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let newRoot = support.appendingPathComponent("ZBS Eye", isDirectory: true)
        let oldRoot = support.appendingPathComponent("Slishu", isDirectory: true)
        // База в старой папке могла называться и по новому, и по прежнему имени — проверяем оба.
        let oldHasDB = fm.fileExists(atPath: oldRoot.appendingPathComponent("zbseye.sqlite").path)
            || fm.fileExists(atPath: oldRoot.appendingPathComponent("slishu.sqlite").path)
        let newHasDB = fm.fileExists(atPath: newRoot.appendingPathComponent("zbseye.sqlite").path)
            || fm.fileExists(atPath: newRoot.appendingPathComponent("slishu.sqlite").path)
        guard !newHasDB, oldHasDB else { return }
        if !fm.fileExists(atPath: newRoot.path) {
            try? fm.moveItem(at: oldRoot, to: newRoot)            // атомарный rename всей папки
        } else {
            for item in (try? fm.contentsOfDirectory(at: oldRoot, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.moveItem(at: item, to: newRoot.appendingPathComponent(item.lastPathComponent))
            }
        }
    }

    /// ОДНОРАЗОВАЯ миграция имени файла базы на новое (в текущем root — учитывает relocate). Старое имя
    /// → новое вместе с WAL/SHM-сайдкарами (переименовывать БД на середине WAL нельзя — но это до
    /// открытия пула любым процессом, файлы в покое). Вызывать ПОСЛЕ defaults- и dir-миграций.
    static func migrateDatabaseFilenameIfNeeded() {
        let fm = FileManager.default
        let root = dataRoot()
        let new = root.appendingPathComponent("zbseye.sqlite")
        guard !fm.fileExists(atPath: new.path),
              fm.fileExists(atPath: root.appendingPathComponent("slishu.sqlite").path) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let from = root.appendingPathComponent("slishu.sqlite" + suffix)
            let to = root.appendingPathComponent("zbseye.sqlite" + suffix)
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: to) }
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
