import Foundation
import GRDB

// MARK: - Models

public struct SlishuAppModel: Codable, FetchableRecord, TableRecord, MutablePersistableRecord {
    public static let databaseTableName = "apps"
    
    public var id: Int64?
    public let bundleIdentifier: String
    public let name: String
    
    public init(id: Int64? = nil, bundleIdentifier: String, name: String) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
    
    mutating public func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct SlishuScreenCapture: Codable, FetchableRecord, TableRecord, MutablePersistableRecord {
    public static let databaseTableName = "screen_captures"
    
    public var id: Int64?
    public let timestamp: Date
    public let appId: Int64?
    public let monitorId: String
    public let relativePath: String
    
    public init(id: Int64? = nil, timestamp: Date = Date(), appId: Int64?, monitorId: String, relativePath: String) {
        self.id = id
        self.timestamp = timestamp
        self.appId = appId
        self.monitorId = monitorId
        self.relativePath = relativePath
    }
    
    mutating public func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct SlishuOcrElement: Codable, FetchableRecord, TableRecord, MutablePersistableRecord {
    public static let databaseTableName = "ocr_elements"
    
    public var id: Int64?
    public let captureId: Int64
    public let text: String
    public let confidence: Double
    public let left: Double
    public let top: Double
    public let width: Double
    public let height: Double
    
    public init(id: Int64? = nil, captureId: Int64, text: String, confidence: Double, left: Double, top: Double, width: Double, height: Double) {
        self.id = id
        self.captureId = captureId
        self.text = text
        self.confidence = confidence
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
    
    mutating public func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct SlishuAudioCapture: Codable, FetchableRecord, TableRecord, MutablePersistableRecord {
    public static let databaseTableName = "audio_captures"
    
    public var id: Int64?
    public let timestamp: Date
    public let relativePath: String
    public let durationSeconds: Double
    
    public init(id: Int64? = nil, timestamp: Date = Date(), relativePath: String, durationSeconds: Double) {
        self.id = id
        self.timestamp = timestamp
        self.relativePath = relativePath
        self.durationSeconds = durationSeconds
    }
    
    mutating public func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct SlishuAudioTranscription: Codable, FetchableRecord, TableRecord, MutablePersistableRecord {
    public static let databaseTableName = "audio_transcriptions"
    
    public var id: Int64?
    public let audioCaptureId: Int64
    public let text: String
    public let language: String
    
    public init(id: Int64? = nil, audioCaptureId: Int64, text: String, language: String) {
        self.id = id
        self.audioCaptureId = audioCaptureId
        self.text = text
        self.language = language
    }
    
    mutating public func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct SlishuSemanticEmbedding: Codable, FetchableRecord, TableRecord, MutablePersistableRecord {
    public static let databaseTableName = "semantic_embeddings"
    
    public var id: Int64?
    public let captureId: Int64?
    public let audioCaptureId: Int64?
    public let vectorBlob: Data // Array of Float serialized
    
    public init(id: Int64? = nil, captureId: Int64? = nil, audioCaptureId: Int64? = nil, vector: [Float]) {
        self.id = id
        self.captureId = captureId
        self.audioCaptureId = audioCaptureId
        
        // Serialize [Float] to Data
        var data = Data(capacity: vector.count * MemoryLayout<Float>.size)
        for val in vector {
            var value = val
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        self.vectorBlob = data
    }
    
    public var vector: [Float] {
        var result = [Float]()
        let elementCount = vectorBlob.count / MemoryLayout<Float>.size
        result.reserveCapacity(elementCount)
        vectorBlob.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            let floatPointer = baseAddress.assumingMemoryBound(to: Float.self)
            for i in 0..<elementCount {
                result.append(floatPointer[i])
            }
        }
        return result
    }
    
    mutating public func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Database Manager

public final class SlishuDatabase {
    public static let shared = SlishuDatabase()
    
    private var dbPool: DatabasePool?
    private let fileManager = FileManager.default
    
    // UserDefaults ключи для хранения настроек путей
    private let customStoragePathKey = "SlishuCustomStoragePath"
    
    private init() {
        do {
            try setupDatabase()
        } catch {
            print("❌ Ошибка инициализации базы данных Slishu: \(error)")
        }
    }
    
    // Директория хранения медиа-файлов (HEIC кадров и FLAC аудио)
    public var mediaDirectory: URL {
        if let customPath = UserDefaults.standard.string(forKey: customStoragePathKey) {
            let url = URL(fileURLWithPath: customPath)
            // Создаем директорию если её нет
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let defaultMediaUrl = appSupport.appendingPathComponent("Slishu/media", isDirectory: true)
        try? fileManager.createDirectory(at: defaultMediaUrl, withIntermediateDirectories: true)
        return defaultMediaUrl
    }
    
    // Путь к файлу базы данных SQLite
    public var databasePath: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Slishu/slishu.sqlite")
    }
    
    // Установка кастомного пути для хранения медиа
    public func setCustomStorageDirectory(path: String) throws {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw NSError(domain: "SlishuDatabase", code: 1, userInfo: [NSLocalizedDescriptionKey: "Указанный путь не является папкой"])
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        
        UserDefaults.standard.set(path, forKey: customStoragePathKey)
        print("📁 Хранилище медиа перенаправлено в: \(path)")
    }
    
    // Сбросить настройки пути к хранилищу на значения по умолчанию
    public func resetStorageDirectory() {
        UserDefaults.standard.removeObject(forKey: customStoragePathKey)
    }
    
    private func setupDatabase() throws {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDirectory = appSupport.appendingPathComponent("Slishu", isDirectory: true)
        try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        
        let dbUrl = dbDirectory.appendingPathComponent("slishu.sqlite")
        print("💾 База данных Slishu инициализирована по адресу: \(dbUrl.path)")
        
        var config = Configuration()
        config.qos = .userInitiated
        // Включаем WAL режим для параллельного чтения и записи без взаимных блокировок
        config.journalMode = .wal
        
        let pool = try DatabasePool(path: dbUrl.path, configuration: config)
        self.dbPool = pool
        
        try runMigrations(pool)
    }
    
    private func runMigrations(_ writer: DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        
        migrator.registerMigration("v1_create_schema") { db in
            // Таблица приложений
            try db.create(table: "apps") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bundleIdentifier", .text).notNull().unique(onConflict: .ignore)
                t.column("name", .text).notNull()
            }
            
            // Таблица снимков экрана
            try db.create(table: "screen_captures") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("appId", .integer).references("apps", onDelete: .setNull)
                t.column("monitorId", .text).notNull()
                t.column("relativePath", .text).notNull()
            }
            
            // Таблица OCR элементов (распознанные слова с координатами)
            try db.create(table: "ocr_elements") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("captureId", .integer).notNull().references("screen_captures", onDelete: .cascade).indexed()
                t.column("text", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("left", .double).notNull()
                t.column("top", .double).notNull()
                t.column("width", .double).notNull()
                t.column("height", .double).notNull()
            }
            
            // Таблица аудиозаписей
            try db.create(table: "audio_captures") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("relativePath", .text).notNull()
                t.column("durationSeconds", .double).notNull()
            }
            
            // Таблица текстовых расшифровок аудио
            try db.create(table: "audio_transcriptions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("audioCaptureId", .integer).notNull().references("audio_captures", onDelete: .cascade).indexed()
                t.column("text", .text).notNull()
                t.column("language", .text).notNull()
            }
            
            // Создание виртуальной таблицы FTS5 для сверхбыстрого полнотекстового поиска
            try db.execute(sql: """
                CREATE VIRTUAL TABLE ocr_fts USING fts5(
                    captureId UNINDEXED,
                    text,
                    tokenize='unicode61'
                )
            """)
            
            // Триггер для очистки индекса FTS5 при удалении снимка экрана
            try db.execute(sql: """
                CREATE TRIGGER screen_captures_ad AFTER DELETE ON screen_captures BEGIN
                    DELETE FROM ocr_fts WHERE captureId = old.id;
                END;
            """)
            
            // Виртуальная таблица FTS5 для аудиозаписей
            try db.execute(sql: """
                CREATE VIRTUAL TABLE audio_fts USING fts5(
                    audioCaptureId UNINDEXED,
                    text,
                    tokenize='unicode61'
                )
            """)
            
            // Триггер для индексации аудио при добавлении транскрипции
            try db.execute(sql: """
                CREATE TRIGGER audio_transcriptions_ai AFTER INSERT ON audio_transcriptions BEGIN
                    INSERT INTO audio_fts(audioCaptureId, text) VALUES (new.audioCaptureId, new.text);
                END;
            """)
            
            // Триггер для очистки индекса аудио при удалении аудиозаписи
            try db.execute(sql: """
                CREATE TRIGGER audio_captures_ad AFTER DELETE ON audio_captures BEGIN
                    DELETE FROM audio_fts WHERE audioCaptureId = old.id;
                END;
            """)
        }
        
        migrator.registerMigration("v2_add_vector_embeddings") { db in
            // Таблица векторных эмбеддингов для локального семантического поиска
            try db.create(table: "semantic_embeddings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("captureId", .integer).references("screen_captures", onDelete: .cascade).indexed()
                t.column("audioCaptureId", .integer).references("audio_captures", onDelete: .cascade).indexed()
                t.column("vectorBlob", .blob).notNull()
            }
        }
        
        try migrator.migrate(writer)
    }
    
    // MARK: - CRUD операции
    
    public func getDatabasePool() -> DatabasePool {
        guard let pool = dbPool else {
            fatalError("База данных Slishu не была настроена должным образом")
        }
        return pool
    }
}
