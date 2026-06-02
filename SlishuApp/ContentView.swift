import SwiftUI
import AppKit
import GRDB

// MARK: - Navigation Tab Enum
enum SlishuTab: String, CaseIterable, Identifiable {
    case timeline = "Таймлайн"
    case pipes = "Плагины"
    case connections = "Подключения"
    case settings = "Настройки"
    
    var id: String { self.rawValue }
    
    var icon: String {
        switch self {
        case .timeline: return "square.dashed.inset.filled"
        case .pipes: return "puzzlepiece.fill"
        case .connections: return "cable.connector"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Mock Models for Pipes & Connections
struct PipeItem: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let gradient: [Color]
    var isActive: Bool
    let tag: String
}

struct ConnectionItem: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String
    var isConnected: Bool
    let type: String
}

// MARK: - Visual Effect Blur (Glassmorphism helper)
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Main ContentView
struct ContentView: View {
    @State private var selectedTab: SlishuTab = .timeline
    
    // Core state
    @State private var searchQuery = ""
    @State private var isRecording = SlishuCapture.shared.isCapturing
    @State private var tccErrorActive = SlishuCapture.shared.hasTccPermissionError
    @State private var storagePath = SlishuDatabase.shared.mediaDirectory.path
    @State private var screenCount = 0
    @State private var audioCount = 0
    
    // Search Results
    @State private var searchResults: [SearchResultItem] = []
    @State private var semanticSearchActive = false
    
    // Timeline Travel State
    @State private var timelineCaptures: [TimelineCaptureMetadata] = []
    @State private var timelineIndex: Double = 0.0
    @State private var selectedImage: NSImage? = nil
    @State private var selectedCaptureText = ""
    @State private var selectedCaptureApp = ""
    @State private var selectedCaptureTime = Date()
    @State private var isTimelinePlaying = false
    @State private var playTask: Task<Void, Never>? = nil
    
    // Mocks for Pipes & Connections
    @State private var pipesList: [PipeItem] = [
        PipeItem(id: "gmail_summary", name: "Gmail Summarizer", description: "Локальный ИИ анализирует вашу почту и формирует ежедневный дайджест важных писем.", icon: "envelope.fill", gradient: [.red, .orange], isActive: false, tag: "LOCAL AI"),
        PipeItem(id: "slack_highlights", name: "Slack Highlights", description: "Группирует важные упоминания, поручения и обсуждения из ваших каналов Slack за день.", icon: "bubble.left.and.bubble.right.fill", gradient: [.purple, .indigo], isActive: false, tag: "CONNECTOR"),
        PipeItem(id: "obsidian_sync", name: "Obsidian Sync", description: "Автоматически экспортирует ваши выводы, транскрипты встреч и итоги дня в Obsidian Daily Notes.", icon: "leaf.fill", gradient: [.emerald, .teal], isActive: true, tag: "AUTOMATION"),
        PipeItem(id: "local_assistant", name: "Ollama Auto-Assistant", description: "Интеллектуальный помощник на базе локальной модели Llama 3, отвечающий по контексту вашего экрана.", icon: "brain.head.profile", gradient: [.blue, .purple], isActive: true, tag: "LOCAL AI")
    ]
    
    @State private var connectionsList: [ConnectionItem] = [
        ConnectionItem(id: "obsidian", name: "Obsidian Local Vault", description: "Подключение к вашему локальному архиву заметок Obsidian.", icon: "leaf.fill", isConnected: true, type: "Локальный"),
        ConnectionItem(id: "notion", name: "Notion Workspace", description: "Экспорт аналитики и саммари встреч в базы данных Notion.", icon: "doc.text.fill", isConnected: false, type: "Cloud API"),
        ConnectionItem(id: "slack", name: "Slack Integration", description: "Интеграция со Slack для отправки уведомлений и дайджестов.", icon: "message.fill", isConnected: false, type: "Webhooks"),
        ConnectionItem(id: "google", name: "Google Calendar & Gmail", description: "Контекстный анализ запланированных встреч и входящих писем.", icon: "calendar", isConnected: false, type: "OAuth 2.0")
    ]
    
    // Timers
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 0) {
            // MARK: - LEFT SIDEBAR
            VStack(spacing: 0) {
                // App Logo and title
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 32, height: 32)
                            .shadow(color: .indigo.opacity(0.4), radius: 6, x: 0, y: 3)
                        
                        Image(systemName: "waveform")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .symbolEffect(.bounce, options: .repeating, value: isRecording)
                    }
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Slishu")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text("Local Timeline")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 24)
                
                // Sidebar Navigation Links
                VStack(spacing: 4) {
                    ForEach(SlishuTab.allCases) { tab in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 18, alignment: .center)
                                
                                Text(tab.rawValue)
                                    .font(.system(size: 13, weight: .medium))
                                
                                Spacer()
                                
                                // Специальная плашка для Настроек если есть ошибка TCC
                                if tab == .settings && tccErrorActive {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.amber)
                                        .font(.system(size: 12))
                                        .symbolEffect(.pulse, value: tccErrorActive)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundColor(selectedTab == tab ? .white : .primary.opacity(0.8))
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedTab == tab ?
                                          LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing) :
                                          LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                
                Spacer()
                
                // TCC Warning Block in Sidebar
                if tccErrorActive {
                    Button(action: {
                        withAnimation {
                            selectedTab = .settings
                        }
                    }) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("🔐 Ошибка прав TCC")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.amber)
                            
                            Text("Нажмите для настройки записи экрана.")
                                .font(.system(size: 10))
                                .foregroundColor(.amber.opacity(0.8))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.amber.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.amber.opacity(0.3), lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .buttonStyle(.plain)
                }
                
                // Bottom Sidebar Status Block
                VStack(spacing: 8) {
                    Divider().padding(.horizontal, 12)
                    
                    HStack {
                        // Анимированная кнопка Статуса/Записи
                        Button(action: toggleCapture) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(tccErrorActive ? Color.amber : (isRecording ? Color.red : Color.gray))
                                    .frame(width: 8, height: 8)
                                    .scaleEffect(isRecording ? 1.2 : 1.0)
                                    .animation(isRecording ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isRecording)
                                
                                Text(tccErrorActive ? "ЗАБЛОКИРОВАНО" : (isRecording ? "ЗАПИСЬ ИДЕТ" : "НА ПАУЗЕ"))
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(tccErrorActive ? .amber : (isRecording ? .red : .secondary))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(tccErrorActive ? Color.amber.opacity(0.12) : (isRecording ? Color.red.opacity(0.1) : Color.primary.opacity(0.04)))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(tccErrorActive ? Color.amber.opacity(0.3) : (isRecording ? Color.red.opacity(0.2) : Color.clear), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                        
                        // REST API Indicator
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                                .font(.system(size: 10))
                            Text("API")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(.emerald)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.emerald.opacity(0.12)))
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                    .padding(.top, 8)
                }
            }
            .frame(width: 220)
            .background(
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            )
            
            Divider()
            
            // MARK: - RIGHT DETAIL AREA
            ZStack {
                // Main dark background gradient
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor).opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    switch selectedTab {
                    case .timeline:
                        TimelineTabView(
                            searchQuery: $searchQuery,
                            searchResults: $searchResults,
                            semanticSearchActive: $semanticSearchActive,
                            timelineCaptures: $timelineCaptures,
                            timelineIndex: $timelineIndex,
                            selectedImage: $selectedImage,
                            selectedCaptureText: $selectedCaptureText,
                            selectedCaptureApp: $selectedCaptureApp,
                            selectedCaptureTime: $selectedCaptureTime,
                            isTimelinePlaying: $isTimelinePlaying,
                            screenCount: screenCount,
                            audioCount: audioCount,
                            isRecording: isRecording,
                            togglePlayTimeline: togglePlayTimeline,
                            loadTimelineFrame: loadTimelineFrame,
                            performSearch: performSearch
                        )
                    case .pipes:
                        PipesTabView(pipes: $pipesList)
                    case .connections:
                        ConnectionsTabView(connections: $connectionsList)
                    case .settings:
                        SettingsTabView(
                            storagePath: $storagePath,
                            tccErrorActive: $tccErrorActive,
                            screenCount: screenCount,
                            audioCount: audioCount,
                            selectCustomDirectory: selectCustomDirectory,
                            updateStats: updateStats,
                            updateTimeline: updateTimeline
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 950, minHeight: 650)
        .onAppear {
            updateStats()
            updateTimeline()
            // Launch FlyingFox API & MCP Server
            SlishuServer.shared.start()
        }
        .onReceive(timer) { _ in
            updateStats()
            if searchQuery.isEmpty && selectedTab == .timeline {
                updateTimelineIfNeeded()
            }
        }
    }
    
    // MARK: - Business Logic Actions
    
    private func toggleCapture() {
        if isRecording {
            SlishuCapture.shared.stopCapture()
        } else {
            SlishuCapture.shared.startCapture()
        }
        // Force refresh state immediately
        isRecording = SlishuCapture.shared.isCapturing
        tccErrorActive = SlishuCapture.shared.hasTccPermissionError
    }
    
    private func updateStats() {
        isRecording = SlishuCapture.shared.isCapturing
        tccErrorActive = SlishuCapture.shared.hasTccPermissionError
        storagePath = SlishuDatabase.shared.mediaDirectory.path
        
        Task.detached(priority: .background) {
            let dbPool = SlishuDatabase.shared.getDatabasePool()
            do {
                let (screens, audios) = try await dbPool.read { db in
                    let sCount = try SlishuScreenCapture.fetchCount(db)
                    let aCount = try SlishuAudioCapture.fetchCount(db)
                    return (sCount, aCount)
                }
                await MainActor.run {
                    self.screenCount = screens
                    self.audioCount = audios
                }
            } catch {
                print("❌ Ошибка при чтении статистики из БД: \(error)")
            }
        }
    }
    
    private func updateTimelineIfNeeded() {
        if timelineCaptures.count == screenCount {
            return
        }
        updateTimeline()
    }
    
    private func updateTimeline() {
        Task.detached(priority: .userInitiated) {
            let dbPool = SlishuDatabase.shared.getDatabasePool()
            do {
                let captures = try await dbPool.read { dbReader in
                    let rows = try Row.fetchAll(dbReader, sql: """
                        SELECT c.id, c.timestamp, c.relativePath, a.name as appName
                        FROM screen_captures c
                        LEFT JOIN apps a ON a.id = c.appId
                        ORDER BY c.timestamp ASC
                    """)
                    return rows.map { row in
                        TimelineCaptureMetadata(
                            id: row["id"] ?? 0,
                            timestamp: row["timestamp"] ?? Date(),
                            relativePath: row["relativePath"] ?? "",
                            appName: row["appName"] ?? "Неизвестно"
                        )
                    }
                }
                
                await MainActor.run {
                    let countChanged = (self.timelineCaptures.count != captures.count)
                    self.timelineCaptures = captures
                    
                    if countChanged && !captures.isEmpty {
                        self.timelineIndex = Double(captures.count - 1)
                        self.loadTimelineFrame(at: captures.count - 1)
                    }
                }
            } catch {
                print("❌ Ошибка загрузки таймлайна: \(error)")
            }
        }
    }
    
    private func loadTimelineFrame(at index: Int) {
        guard index >= 0 && index < timelineCaptures.count else { return }
        let capture = timelineCaptures[index]
        
        let captureId = capture.id
        let appName = capture.appName
        let timestamp = capture.timestamp
        let relativePath = capture.relativePath
        
        self.selectedCaptureApp = appName
        self.selectedCaptureTime = timestamp
        
        Task.detached(priority: .userInitiated) {
            let mediaDir = SlishuDatabase.shared.mediaDirectory
            let path = mediaDir.appendingPathComponent(relativePath)
            let image = NSImage(contentsOf: path)
            
            let dbPool = SlishuDatabase.shared.getDatabasePool()
            let ocrText = (try? await dbPool.read { dbReader in
                try String.fetchOne(dbReader, sql: "SELECT text FROM ocr_fts WHERE captureId = ?", arguments: [captureId])
            }) ?? ""
            
            await MainActor.run {
                if Int(self.timelineIndex) == index {
                    self.selectedImage = image
                    self.selectedCaptureText = ocrText
                }
            }
        }
    }
    
    private func togglePlayTimeline() {
        if isTimelinePlaying {
            isTimelinePlaying = false
            playTask?.cancel()
            playTask = nil
        } else {
            isTimelinePlaying = true
            playTask = Task {
                while isTimelinePlaying && !timelineCaptures.isEmpty {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if Task.isCancelled { break }
                    await MainActor.run {
                        if timelineIndex < Double(timelineCaptures.count - 1) {
                            timelineIndex += 1.0
                            loadTimelineFrame(at: Int(timelineIndex))
                        } else {
                            timelineIndex = 0.0
                            loadTimelineFrame(at: 0)
                        }
                    }
                }
                await MainActor.run {
                    isTimelinePlaying = false
                }
            }
        }
    }
    
    private func selectCustomDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Выберите папку для хранения записей Slishu"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try SlishuDatabase.shared.setCustomStorageDirectory(path: url.path)
                storagePath = url.path
                updateTimeline()
            } catch {
                print("❌ Ошибка смены папки: \(error)")
            }
        }
    }
    
    private func performSearch() {
        guard !searchQuery.isEmpty else {
            searchResults = []
            return
        }
        
        let query = searchQuery
        let isSemantic = semanticSearchActive
        
        Task.detached(priority: .userInitiated) {
            let dbPool = SlishuDatabase.shared.getDatabasePool()
            
            if isSemantic {
                guard let queryVector = SlishuSemanticSearcher.shared.getEmbedding(for: query) else {
                    await MainActor.run {
                        self.searchResults = []
                    }
                    return
                }
                
                do {
                    let items: [SearchResultItem] = try await dbPool.read { dbReader in
                        let allEmbeddings = try SlishuSemanticEmbedding.fetchAll(dbReader)
                        var scoredItems: [(embedding: SlishuSemanticEmbedding, score: Float)] = []
                        
                        for emb in allEmbeddings {
                            let score = SlishuSemanticSearcher.cosineSimilarity(queryVector, emb.vector)
                            if score >= 0.35 {
                                scoredItems.append((emb, score))
                            }
                        }
                        
                        scoredItems.sort { $0.score > $1.score }
                        let topScored = scoredItems.prefix(30)
                        var tempItems: [SearchResultItem] = []
                        
                        for (emb, score) in topScored {
                            if let captureId = emb.captureId {
                                if let capture = try SlishuScreenCapture.filter(Column("id") == captureId).fetchOne(dbReader) {
                                    let appName = try String.fetchOne(dbReader, sql: "SELECT name FROM apps WHERE id = ?", arguments: [capture.appId]) ?? "Приложение"
                                    let ocrText = try String.fetchOne(dbReader, sql: "SELECT text FROM ocr_fts WHERE captureId = ?", arguments: [captureId]) ?? ""
                                    
                                    tempItems.append(SearchResultItem(
                                        id: UUID(),
                                        type: .screen,
                                        timestamp: capture.timestamp,
                                        appName: appName,
                                        mediaPath: capture.relativePath,
                                        text: ocrText,
                                        score: score
                                    ))
                                }
                            } else if let audioCaptureId = emb.audioCaptureId {
                                if let audioCapture = try SlishuAudioCapture.filter(Column("id") == audioCaptureId).fetchOne(dbReader) {
                                    let text = try String.fetchOne(dbReader, sql: "SELECT text FROM audio_transcriptions WHERE audioCaptureId = ?", arguments: [audioCaptureId]) ?? ""
                                    
                                    tempItems.append(SearchResultItem(
                                        id: UUID(),
                                        type: .audio,
                                        timestamp: audioCapture.timestamp,
                                        appName: "Разговор (Аудиозапись)",
                                        mediaPath: audioCapture.relativePath,
                                        text: text,
                                        score: score
                                    ))
                                }
                            }
                        }
                        return tempItems
                    }
                    
                    await MainActor.run {
                        if self.searchQuery == query && self.semanticSearchActive == isSemantic {
                            self.searchResults = items
                        }
                    }
                } catch {
                    print("❌ Ошибка при семантическом поиске: \(error)")
                }
            } else {
                do {
                    let items: [SearchResultItem] = try await dbPool.read { dbReader in
                        var tempItems: [SearchResultItem] = []
                        
                        let screenRows = try Row.fetchAll(dbReader, sql: """
                            SELECT c.id, c.timestamp, c.relativePath, a.name as appName, f.text
                            FROM ocr_fts f
                            JOIN screen_captures c ON c.id = f.captureId
                            JOIN apps a ON a.id = c.appId
                            WHERE ocr_fts MATCH ?
                            ORDER BY c.timestamp DESC LIMIT 30
                        """, arguments: [query])
                        
                        for row in screenRows {
                            tempItems.append(SearchResultItem(
                                id: UUID(),
                                type: .screen,
                                timestamp: row["timestamp"] ?? Date(),
                                appName: row["appName"] ?? "Приложение",
                                mediaPath: row["relativePath"] ?? "",
                                text: row["text"] ?? ""
                            ))
                        }
                        
                        let audioRows = try Row.fetchAll(dbReader, sql: """
                            SELECT ac.id, ac.timestamp, ac.relativePath, ac.durationSeconds, af.text
                            FROM audio_fts af
                            JOIN audio_captures ac ON ac.id = af.audioCaptureId
                            WHERE audio_fts MATCH ?
                            ORDER BY ac.timestamp DESC LIMIT 30
                        """, arguments: [query])
                        
                        for row in audioRows {
                            tempItems.append(SearchResultItem(
                                id: UUID(),
                                type: .audio,
                                timestamp: row["timestamp"] ?? Date(),
                                appName: "Разговор (Аудиозапись)",
                                mediaPath: row["relativePath"] ?? "",
                                text: row["text"] ?? ""
                            ))
                        }
                        return tempItems
                    }
                    
                    let sortedItems = items.sorted { $0.timestamp > $1.timestamp }
                    await MainActor.run {
                        if self.searchQuery == query && self.semanticSearchActive == isSemantic {
                            self.searchResults = sortedItems
                        }
                    }
                } catch {
                    print("❌ Ошибка при поиске: \(error)")
                }
            }
        }
    }
}

// MARK: - TIMELINE TAB VIEW
struct TimelineTabView: View {
    @Binding var searchQuery: String
    @Binding var searchResults: [SearchResultItem]
    @Binding var semanticSearchActive: Bool
    
    @Binding var timelineCaptures: [TimelineCaptureMetadata]
    @Binding var timelineIndex: Double
    @Binding var selectedImage: NSImage?
    @Binding var selectedCaptureText: String
    @Binding var selectedCaptureApp: String
    @Binding var selectedCaptureTime: Date
    @Binding var isTimelinePlaying: Bool
    
    let screenCount: Int
    let audioCount: Int
    let isRecording: Bool
    
    let togglePlayTimeline: () -> Void
    let loadTimelineFrame: (Int) -> Void
    let performSearch: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Stats top summary widgets
            HStack(spacing: 16) {
                DashboardCard(
                    title: "Кадры экрана",
                    count: "\(screenCount)",
                    icon: "square.dashed.inset.filled",
                    gradient: [.blue, .cyan]
                )
                
                DashboardCard(
                    title: "Аудиозаписи",
                    count: "\(audioCount)",
                    icon: "mic.fill",
                    gradient: [.indigo, .purple]
                )
                
                DashboardCard(
                    title: "Семантический индекс",
                    count: screenCount > 0 ? "Готов" : "Ожидание",
                    icon: "brain.head.profile",
                    gradient: [.emerald, .teal]
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            
            // Spotlight Search Bar
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.indigo)
                    
                    TextField("Ищите всё, что вы видели или слышали на вашем Mac...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .regular))
                        .onSubmit {
                            performSearch()
                        }
                    
                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = ""; searchResults = [] }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Divider().frame(height: 16)
                    
                    // AI Semantic Search Toggle Button
                    Button(action: {
                        withAnimation {
                            semanticSearchActive.toggle()
                        }
                        if !searchQuery.isEmpty {
                            performSearch()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 13))
                                .symbolEffect(.bounce, value: semanticSearchActive)
                            Text("ИИ Поиск")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundColor(semanticSearchActive ? .white : .secondary)
                        .background(
                            Capsule()
                                .fill(semanticSearchActive ? Color.indigo : Color.clear)
                        )
                        .overlay(
                            Capsule()
                                .stroke(semanticSearchActive ? Color.clear : Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Умный локальный семантический поиск по смыслу")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(LinearGradient(colors: [.indigo.opacity(0.4), .purple.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                        )
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            
            // Timeline Content
            VStack(spacing: 0) {
                if searchQuery.isEmpty {
                    if timelineCaptures.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 36))
                                .foregroundColor(.indigo.opacity(0.5))
                            
                            Text("Таймлайн пуст. Начните запись экрана для накопления истории.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HSplitView {
                            // Left screen preview area
                            VStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.black.opacity(0.3))
                                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                                    
                                    if let image = selectedImage {
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .cornerRadius(8)
                                            .padding(6)
                                    } else {
                                        VStack(spacing: 8) {
                                            ProgressView().controlSize(.small)
                                            Text("Загрузка кадра...")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                
                                // Time Travel Scrubber Block
                                VStack(spacing: 8) {
                                    HStack(spacing: 12) {
                                        Button(action: togglePlayTimeline) {
                                            Image(systemName: isTimelinePlaying ? "pause.fill" : "play.fill")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.white)
                                                .frame(width: 30, height: 30)
                                                .background(Circle().fill(Color.indigo))
                                                .shadow(color: .indigo.opacity(0.3), radius: 4, x: 0, y: 2)
                                        }
                                        .buttonStyle(.plain)
                                        
                                        Slider(value: $timelineIndex, in: 0...Double(max(0, timelineCaptures.count - 1)), step: 1.0) { _ in
                                            loadTimelineFrame(Int(timelineIndex))
                                        }
                                        .accentColor(.indigo)
                                    }
                                    .padding(.horizontal, 16)
                                    
                                    HStack {
                                        Text(timelineCaptures.first.map { formatDate($0.timestamp) } ?? "")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                        
                                        Spacer()
                                        
                                        Text("\(Int(timelineIndex) + 1) из \(timelineCaptures.count)")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.indigo)
                                        
                                        Spacer()
                                        
                                        Text(timelineCaptures.last.map { formatDate($0.timestamp) } ?? "")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 12)
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.primary.opacity(0.02))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
                                        )
                                        .padding(.horizontal, 8)
                                )
                            }
                            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                            
                            // Right Details panel
                            VStack(alignment: .leading, spacing: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "info.circle.fill")
                                            .foregroundColor(.indigo)
                                        Text("Детализация кадра")
                                            .font(.system(size: 13, weight: .bold))
                                    }
                                    
                                    Divider()
                                    
                                    HStack {
                                        Text("Приложение:")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text(selectedCaptureApp)
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.indigo)
                                    }
                                    
                                    HStack {
                                        Text("Время снимка:")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text(formatDate(selectedCaptureTime))
                                            .font(.system(size: 11))
                                            .foregroundColor(.primary)
                                    }
                                }
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("РАСПОЗНАННЫЙ OCR ТЕКСТ")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.secondary)
                                    
                                    if selectedCaptureText.isEmpty {
                                        VStack(spacing: 8) {
                                            Image(systemName: "text.justify.left")
                                                .font(.system(size: 20))
                                                .foregroundColor(.secondary.opacity(0.4))
                                            Text("Текст на экране не обнаружен")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.01)))
                                    } else {
                                        ScrollView {
                                            Text(selectedCaptureText)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.primary.opacity(0.85))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(10)
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.02)))
                                    }
                                }
                                .frame(maxHeight: .infinity)
                            }
                            .frame(minWidth: 200, idealWidth: 260, maxWidth: 320, maxHeight: .infinity)
                            .padding(.trailing, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                        }
                    }
                } else {
                    // Search Results List
                    if searchResults.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 36))
                                .foregroundColor(.indigo.opacity(0.5))
                            
                            Text("Ничего не найдено по этому запросу.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(searchResults) { item in
                                    TimelineRow(item: item)
                                }
                            }
                            .padding(20)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - PIPES TAB VIEW
struct PipesTabView: View {
    @Binding var pipes: [PipeItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("Плагины & Автоматизации (Pipes)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Локальные фоновые скрипты, обрабатывающие ваши сырые данные экрана и звука.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            
            Divider().padding(.vertical, 16)
            
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320))], spacing: 16) {
                    ForEach(pipes.indices, id: \.self) { idx in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(LinearGradient(colors: pipes[idx].gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 44, height: 44)
                                    
                                    Image(systemName: pipes[idx].icon)
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pipes[idx].name)
                                        .font(.system(size: 14, weight: .bold))
                                    Text(pipes[idx].tag)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.indigo))
                                }
                                
                                Spacer()
                                
                                Toggle("", isOn: $pipes[idx].isActive)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                            
                            Text(pipes[idx].description)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                                .frame(height: 48, alignment: .top)
                            
                            HStack {
                                Button("Настроить") {
                                    // Mock configure sheet
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                
                                Spacer()
                                
                                if pipes[idx].isActive {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color.emerald).frame(width: 6, height: 6)
                                        Text("Активен в фоне")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.emerald)
                                    }
                                } else {
                                    Text("Приостановлен")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.primary.opacity(0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                                )
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - CONNECTIONS TAB VIEW
struct ConnectionsTabView: View {
    @Binding var connections: [ConnectionItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Подключения & Интеграции")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Свяжите Slishu с внешними базами знаний и аккаунтами для бесшовной интеграции.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            
            Divider().padding(.vertical, 16)
            
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(connections.indices, id: \.self) { idx in
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.indigo.opacity(connections[idx].isConnected ? 0.15 : 0.05))
                                    .frame(width: 42, height: 42)
                                
                                Image(systemName: connections[idx].icon)
                                    .font(.system(size: 18))
                                    .foregroundColor(connections[idx].isConnected ? .indigo : .secondary)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(connections[idx].name)
                                        .font(.system(size: 14, weight: .bold))
                                    
                                    Text(connections[idx].type)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                                }
                                
                                Text(connections[idx].description)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            // Connected status pill
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(connections[idx].isConnected ? Color.emerald : Color.gray)
                                    .frame(width: 6, height: 6)
                                Text(connections[idx].isConnected ? "Подключено" : "Отключено")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(connections[idx].isConnected ? .emerald : .secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(connections[idx].isConnected ? Color.emerald.opacity(0.1) : Color.primary.opacity(0.04)))
                            
                            Button(connections[idx].isConnected ? "Отключить" : "Подключить") {
                                withAnimation {
                                    connections[idx].isConnected.toggle()
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(connections[idx].isConnected ? .red : .indigo)
                            .controlSize(.small)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.primary.opacity(0.02))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.primary.opacity(0.04), lineWidth: 1)
                                )
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - SETTINGS TAB VIEW
struct SettingsTabView: View {
    @Binding var storagePath: String
    @Binding var tccErrorActive: Bool
    
    let screenCount: Int
    let audioCount: Int
    
    let selectCustomDirectory: () -> Void
    let updateStats: () -> Void
    let updateTimeline: () -> Void
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Section Title
                VStack(alignment: .leading, spacing: 6) {
                    Text("Настройки системы")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Конфигурация локального хранилища, баз данных и системных разрешений.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // MARK: - TCC SCREEN CAPTURE DIAGNOSTICS CARD (CRITICAL CASE)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(tccErrorActive ? Color.amber.opacity(0.15) : Color.emerald.opacity(0.15))
                                .frame(width: 36, height: 36)
                            
                            Image(systemName: tccErrorActive ? "lock.trianglebadge.exclamationmark.fill" : "checkmark.shield.fill")
                                .font(.system(size: 16))
                                .foregroundColor(tccErrorActive ? .amber : .emerald)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Разрешение на запись экрана (TCC)")
                                .font(.system(size: 14, weight: .bold))
                            
                            Text(tccErrorActive ? "Доступ заблокирован Системой macOS" : "Доступ успешно предоставлен")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(tccErrorActive ? .amber : .emerald)
                        }
                        
                        Spacer()
                    }
                    
                    if tccErrorActive {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Slishu не может захватывать экран вашего Mac из-за отсутствия разрешений в настройках безопасности macOS (ошибка -3801). Пожалуйста, выполните следующие шаги:")
                                .font(.system(size: 12))
                                .foregroundColor(.primary.opacity(0.85))
                                .lineSpacing(3)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top, spacing: 8) {
                                    Text("1.").fontWeight(.bold).foregroundColor(.indigo)
                                    Text("Нажмите кнопку **«Открыть Системные настройки»** ниже.")
                                        .font(.system(size: 12))
                                }
                                
                                HStack(alignment: .top, spacing: 8) {
                                    Text("2.").fontWeight(.bold).foregroundColor(.indigo)
                                    Text("В списке разрешений найдите приложение **Slishu** и включите переключатель.")
                                        .font(.system(size: 12))
                                }
                                
                                HStack(alignment: .top, spacing: 8) {
                                    Text("3.").fontWeight(.bold).foregroundColor(.indigo)
                                    Text("Если переключатель уже включен, выключите его, подождите 2 секунды и включите обратно.")
                                        .font(.system(size: 12))
                                }
                            }
                            .padding(.leading, 4)
                            
                            HStack(spacing: 12) {
                                Button("Открыть Системные настройки") {
                                    openScreenCaptureSettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.indigo)
                                
                                Button("Проверить повторно") {
                                    // Trigger immediate restart of capture queue to check status
                                    SlishuCapture.shared.stopCapture()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        SlishuCapture.shared.startCapture()
                                        updateStats()
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 4)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.02)))
                    } else {
                        Text("Slishu успешно получает системные кадры с вашего монитора с частотой 0.5 кадров в секунду, используя аппаратное сжатие HEIC и оффлайн-распознавание текста Apple Vision OCR.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineSpacing(3)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(tccErrorActive ? Color.amber.opacity(0.04) : Color.primary.opacity(0.02))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(tccErrorActive ? Color.amber.opacity(0.25) : Color.primary.opacity(0.05), lineWidth: 1)
                        )
                )
                
                // MARK: - STORAGE DIRECTORY PANEL
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.indigo)
                        Text("Хранилище медиафайлов")
                            .font(.system(size: 14, weight: .bold))
                    }
                    
                    Text("Здесь сохраняются оптимизированные HEIC-кадры экрана и CAF-аудиозаписи ваших разговоров. Вы можете разместить медиаархив на внешнем SSD для экономии места на основном диске.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineSpacing(3)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(storagePath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.15)))
                            .lineLimit(1)
                        
                        HStack(spacing: 12) {
                            Button("Изменить папку...") {
                                selectCustomDirectory()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.indigo)
                            
                            if storagePath != SlishuDatabase.shared.mediaDirectory.path {
                                Button("Сбросить") {
                                    SlishuDatabase.shared.resetStorageDirectory()
                                    updateStats()
                                    updateTimeline()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.02)))
                
                // MARK: - SQLITE DATABASE PANEL
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "cylinder.split.1x2.fill")
                            .foregroundColor(.indigo)
                        Text("Локальная база данных SQLite")
                            .font(.system(size: 14, weight: .bold))
                    }
                    
                    Text("Все ваши текстовые индексы, OCR-результаты, транскрипты аудио и 512-мерные семантические AI-векторы хранятся в защищенной реляционной базе данных SQLite с включенным WAL-режимом.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineSpacing(3)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SlishuDatabase.shared.databasePath.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.15)))
                            .lineLimit(1)
                        
                        Button("Показать в Finder") {
                            showDatabaseInFinder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.02)))
                
                // Extra options & reset
                VStack(alignment: .leading, spacing: 10) {
                    Text("УСТРАНЕНИЕ СИСТЕМНЫХ СБОЕВ (ДЛЯ РАЗРАБОТЧИКОВ)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    Button("Сбросить базу данных разрешений экрана") {
                        resetTccPermissionsViaTerminal()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                    .help("Удаляет записи о разрешениях приложения в базе macOS TCC")
                }
                .padding(.top, 10)
            }
            .padding(24)
        }
    }
    
    private func openScreenCaptureSettings() {
        let urlStr = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
            print("🚀 Выполнен переход по deep-link в настройки записи экрана macOS.")
        }
    }
    
    private func showDatabaseInFinder() {
        let dbPath = SlishuDatabase.shared.databasePath.path
        NSWorkspace.shared.selectFile(dbPath, inFileViewerRootedAtPath: "")
        print("📁 База данных slishu.sqlite подсвечена в Finder.")
    }
    
    private func resetTccPermissionsViaTerminal() {
        // Run tccutil reset ScreenCapture com.slishu.SlishuApp in background
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", "com.slishu.SlishuApp"]
        
        do {
            try process.run()
            process.waitUntilExit()
            print("🔐 Права TCC ScreenCapture сброшены для bundle com.slishu.SlishuApp")
            // Alert user to restart
            let alert = NSAlert()
            alert.messageText = "Разрешения сброшены"
            alert.informativeText = "Системные права на захват экрана успешно сброшены в macOS. Теперь перезапустите приложение Slishu для получения нового запроса на авторизацию."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            print("❌ Ошибка выполнения tccutil: \(error)")
        }
    }
}

// MARK: - DASHBOARD CARD COMPONENT
struct DashboardCard: View {
    let title: String
    let count: String
    let icon: String
    let gradient: [Color]
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 32, height: 32)
                
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(count)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.primary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.04), lineWidth: 1)
                )
        )
    }
}

// MARK: - TIMELINE ROW VIEW
struct TimelineRow: View {
    let item: SearchResultItem
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: item.type == .screen ? "desktopcomputer" : "mic.bubble.fill")
                    .foregroundColor(item.type == .screen ? .blue : .purple)
                    .font(.system(size: 13))
                
                Text(item.appName)
                    .font(.system(size: 12, weight: .bold))
                
                if let score = item.score {
                    Text(String(format: "%.0f%% сходство", score * 100))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.indigo))
                }
                
                Spacer()
                
                Text(formatDate(item.timestamp))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            Text(item.text)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(isHovered ? 0.04 : 0.015))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.03), lineWidth: 1)
                )
        )
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hover
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Additional Color extension
extension Color {
    static let emerald = Color(red: 16/255, green: 185/255, blue: 129/255)
    static let amber = Color(red: 245/255, green: 158/255, blue: 11/255)
}

// MARK: - Missing Data Models
enum ResultType {
    case screen
    case audio
}

struct SearchResultItem: Identifiable {
    let id: UUID
    let type: ResultType
    let timestamp: Date
    let appName: String
    let mediaPath: String
    let text: String
    var score: Float? = nil
}

struct TimelineCaptureMetadata: Identifiable, Equatable {
    let id: Int64
    let timestamp: Date
    let relativePath: String
    let appName: String
}
