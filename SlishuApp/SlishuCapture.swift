import Foundation
import ScreenCaptureKit
import Vision
import Cocoa
import GRDB

public final class SlishuCapture: NSObject, SCStreamOutput {
    public static let shared = SlishuCapture()
    
    private var stream: SCStream?
    private var _isCapturing = false
    private var _hasTccPermissionError = false
    
    // Thread-safe computed properties to read from any thread
    public var isCapturing: Bool {
        queue.sync { _isCapturing }
    }
    
    public var hasTccPermissionError: Bool {
        queue.sync { _hasTccPermissionError }
    }
    
    private let queue = DispatchQueue(label: "com.slishu.capture.queue", qos: .userInitiated)
    private let ciContext = CIContext(options: nil)
    
    // Хранение предыдущего кадра для сравнения изменений
    private var lastPixelBuffer: CVPixelBuffer?
    private let changeThreshold: Double = 0.02 // Порог изменений (2% пикселей)
    
    private override init() {
        super.init()
    }
    
    // MARK: - API управления захватом
    
    public func startCapture() {
        queue.async { [weak self] in
            guard let self = self, !self._isCapturing else { return }
            
            self._hasTccPermissionError = false
            
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
                guard let self = self else { return }
                self.queue.async {
                    guard let content = content, error == nil else {
                        print("❌ Ошибка получения захватываемого контента: \(String(describing: error))")
                        if let err = error as NSError?, err.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && err.code == -3801 {
                            self._hasTccPermissionError = true
                        }
                        return
                    }
                    
                    guard let display = content.displays.first else {
                        print("⚠️ Мониторы для захвата не найдены")
                        return
                    }
                    
                    // Настраиваем конфигурацию захвата ScreenCaptureKit
                    let config = SCStreamConfiguration()
                    config.width = display.width
                    config.height = display.height
                    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(0.5)) // 1 кадр в 2 секунды (0.5 fps)
                    config.queueDepth = 5
                    
                    // Создаем фильтр контента для полного экрана
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    
                    do {
                        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                        
                        stream.startCapture { [weak self] error in
                            guard let self = self else { return }
                            self.queue.async {
                                if let error = error {
                                    print("❌ Ошибка запуска SCK стрима: \(error)")
                                    let nsErr = error as NSError
                                    if nsErr.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsErr.code == -3801 {
                                        self._hasTccPermissionError = true
                                    }
                                } else {
                                    self._isCapturing = true
                                    self.stream = stream
                                    print("📹 SCK стрим успешно запущен на частоте 0.5 FPS (1 кадр / 2 сек)")
                                    SlishuAudioRecorder.shared.startRecording()
                                }
                            }
                        }
                    } catch {
                        print("❌ Исключение при настройке SCStream: \(error)")
                    }
                }
            }
        }
    }
    
    public func stopCapture() {
        queue.async { [weak self] in
            guard let self = self, self._isCapturing, let stream = self.stream else { return }
            
            stream.stopCapture { [weak self] error in
                guard let self = self else { return }
                self.queue.async {
                    self.stream = nil
                    self._isCapturing = false
                    self.lastPixelBuffer = nil // Предотвращает утечку буфера ScreenCaptureKit
                    print("📹 SCK стрим остановлен")
                    SlishuAudioRecorder.shared.stopRecording()
                }
            }
        }
    }
    
    // MARK: - SCStreamOutput Delegate
    
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        
        autoreleasepool {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            
            // Сравниваем кадры на предмет значимых изменений для экономии диска и процессора
            if let previous = lastPixelBuffer {
                if !hasFrameChanged(current: imageBuffer, previous: previous) {
                    // Изменений нет, пропускаем кадр
                    return
                }
            }
            
            // Сохраняем ссылку на текущий кадр
            lastPixelBuffer = imageBuffer
            
            // Захватываем метаданные активного приложения
            let activeApp = getActiveApplicationInfo()
            
            // Парсим Accessibility дерево активного приложения (первичный быстрый способ извлечения текста)
            var accessibilityText = ""
            if let frontmostApp = NSWorkspace.shared.frontmostApplication {
                accessibilityText = parseAccessibilityText(for: frontmostApp)
            }
            
            // Запускаем OCR на видеокарте через Vision API
            performAppleVisionOCR(on: imageBuffer) { [weak self] ocrText, ocrElements in
                guard let self = self else { return }
                
                // Записываем собранные данные в базу данных в фоновом режиме
                self.saveCaptureToDatabase(
                    appInfo: activeApp,
                    accessibilityText: accessibilityText,
                    ocrText: ocrText,
                    ocrElements: ocrElements,
                    pixelBuffer: imageBuffer
                )
            }
        }
    }
    
    // MARK: - Алгоритмы обработки кадров
    
    // Быстрое попиксельное сравнение на сетке 16x16 в памяти (почти 0% CPU)
    private func hasFrameChanged(current: CVPixelBuffer, previous: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(current)
        let height = CVPixelBufferGetHeight(current)
        
        guard width == CVPixelBufferGetWidth(previous), height == CVPixelBufferGetHeight(previous) else {
            return true
        }
        
        CVPixelBufferLockBaseAddress(current, .readOnly)
        CVPixelBufferLockBaseAddress(previous, .readOnly)
        
        defer {
            CVPixelBufferUnlockBaseAddress(current, .readOnly)
            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
        }
        
        guard let currentPtr = CVPixelBufferGetBaseAddress(current),
              let previousPtr = CVPixelBufferGetBaseAddress(previous) else {
            return true
        }
        
        let currentBytes = currentPtr.assumingMemoryBound(to: UInt8.self)
        let previousBytes = previousPtr.assumingMemoryBound(to: UInt8.self)
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(current)
        
        // Сканируем сетку 16x16 по всему экрану
        let gridX = 16
        let gridY = 16
        var diffCount = 0
        let totalSamples = gridX * gridY
        
        for y in 0..<gridY {
            let sampleY = Int(Double(y) * Double(height) / Double(gridY))
            let currentLine = currentBytes.advanced(by: sampleY * bytesPerRow)
            let previousLine = previousBytes.advanced(by: sampleY * bytesPerRow)
            
            for x in 0..<gridX {
                let sampleX = Int(Double(x) * Double(width) / Double(gridX))
                // SCK буферы обычно ARGB (4 байта на пиксель)
                let pixelOffset = sampleX * 4
                
                let rDiff = abs(Int(currentLine[pixelOffset]) - Int(previousLine[pixelOffset]))
                let gDiff = abs(Int(currentLine[pixelOffset + 1]) - Int(previousLine[pixelOffset + 1]))
                let bDiff = abs(Int(currentLine[pixelOffset + 2]) - Int(previousLine[pixelOffset + 2]))
                
                // Если разница в цвете пикселя больше 15 по любому каналу, считаем его изменившимся
                if (rDiff + gDiff + bDiff) > 15 {
                    diffCount += 1
                }
            }
        }
        
        // Если изменилось более 1% контрольных пикселей, считаем кадр новым
        let changeRatio = Double(diffCount) / Double(totalSamples)
        return changeRatio > 0.01
    }
    
    // Получение информации об активном приложении
    private func getActiveApplicationInfo() -> (bundleId: String, name: String) {
        if let app = NSWorkspace.shared.frontmostApplication {
            return (app.bundleIdentifier ?? "unknown", app.localizedName ?? "Unknown App")
        }
        return ("unknown", "Unknown App")
    }
    
    // MARK: - Парсинг системного дерева доступности (Accessibility API)
    
    private func parseAccessibilityText(for app: NSRunningApplication) -> String {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var textResult = ""
        
        // Рекурсивно обходим дерево доступности окна
        func traverse(element: AXUIElement) {
            var value: AnyObject?
            let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            
            if status == .success, let strValue = value as? String, !strValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textResult += strValue + " "
            }
            
            // Получаем дочерние элементы
            var children: AnyObject?
            let childrenStatus = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            
            if childrenStatus == .success, let childrenArray = children as? [AXUIElement] {
                for child in childrenArray {
                    traverse(element: child)
                }
            }
        }
        
        traverse(element: appElement)
        return textResult.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Apple Vision OCR (GPU-акселерированный)
    
    private func performAppleVisionOCR(on pixelBuffer: CVPixelBuffer, completion: @escaping (String, [SlishuOcrElement]) -> Void) {
        autoreleasepool {
            let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            
            let request = VNRecognizeTextRequest { request, error in
                guard let results = request.results as? [VNRecognizedTextObservation], error == nil else {
                    completion("", [])
                    return
                }
                
                var ocrText = ""
                var elements: [SlishuOcrElement] = []
                
                for observation in results {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string
                    ocrText += text + "\n"
                    
                    let bbox = observation.boundingBox // Координаты от 0.0 до 1.0 (origin в левом нижнем углу)
                    
                    let element = SlishuOcrElement(
                        captureId: 0, // Будет назначено при вставке в БД
                        text: text,
                        confidence: Double(candidate.confidence),
                        left: Double(bbox.origin.x),
                        top: Double(1.0 - bbox.origin.y - bbox.size.height), // Перевод в top-left origin
                        width: Double(bbox.size.width),
                        height: Double(bbox.size.height)
                    )
                    elements.append(element)
                }
                
                completion(ocrText.trimmingCharacters(in: .whitespacesAndNewlines), elements)
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ru-RU", "en-US"]
            
            do {
                try requestHandler.perform([request])
            } catch {
                print("❌ Ошибка Vision OCR на macOS: \(error)")
                completion("", [])
            }
        }
    }
    
    // MARK: - Запись кадра и текста в Базу Данных
    
    private func saveCaptureToDatabase(
        appInfo: (bundleId: String, name: String),
        accessibilityText: String,
        ocrText: String,
        ocrElements: [SlishuOcrElement],
        pixelBuffer: CVPixelBuffer
    ) {
        let db = SlishuDatabase.shared
        let dbPool = db.getDatabasePool()
        
        // Создаем уникальное имя файла для сжатого кадра экрана
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let filename = "screen_\(formatter.string(from: Date())).heic"
        let mediaFilePath = db.mediaDirectory.appendingPathComponent(filename)
        
        // Аппаратное сжатие в формат HEIC с помощью CoreImage и переиспользуемого CIContext
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        do {
            // Сохраняем сжатый кадр
            try ciContext.writeHEIFRepresentation(
                of: ciImage,
                to: mediaFilePath,
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [:]
            )
            
            try dbPool.write { dbWriter in
                // 1. Проверяем или создаем приложение в базе
                var app = try SlishuAppModel.filter(Column("bundleIdentifier") == appInfo.bundleId).fetchOne(dbWriter)
                if app == nil {
                    var newApp = SlishuAppModel(bundleIdentifier: appInfo.bundleId, name: appInfo.name)
                    try newApp.insert(dbWriter)
                    app = newApp
                }
                
                // 2. Вставляем запись снимка экрана
                var capture = SlishuScreenCapture(
                    appId: app?.id,
                    monitorId: "primary",
                    relativePath: filename
                )
                try capture.insert(dbWriter)
                
                guard let captureId = capture.id else { return }
                
                // 3. Записываем OCR элементы
                for var element in ocrElements {
                    element = SlishuOcrElement(
                        captureId: captureId,
                        text: element.text,
                        confidence: element.confidence,
                        left: element.left,
                        top: element.top,
                        width: element.width,
                        height: element.height
                    )
                    try element.insert(dbWriter)
                }
                
                // 4. Если есть Accessibility-текст, записываем его как дополнительный элемент OCR
                if !accessibilityText.isEmpty {
                    var accElement = SlishuOcrElement(
                        captureId: captureId,
                        text: accessibilityText,
                        confidence: 1.0,
                        left: 0, top: 0, width: 0, height: 0
                    )
                    try accElement.insert(dbWriter)
                }
                
                // 5. Консолидируем весь текст и вставляем ОДИН раз напрямую в ocr_fts!
                var consolidatedText = ocrText
                if !accessibilityText.isEmpty {
                    consolidatedText += "\n" + accessibilityText
                }
                let cleanText = consolidatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !cleanText.isEmpty {
                    try dbWriter.execute(
                        sql: "INSERT INTO ocr_fts (captureId, text) VALUES (?, ?)",
                        arguments: [captureId, cleanText]
                    )
                }
                
                // 6. Генерируем фоновый векторный семантический эмбеддинг для кадра
                if let captureId = capture.id, !cleanText.isEmpty {
                    Task.detached(priority: .background) {
                        if let vector = SlishuSemanticSearcher.shared.getEmbedding(for: cleanText) {
                            do {
                                try dbPool.write { dbWriter in
                                    var embed = SlishuSemanticEmbedding(captureId: captureId, vector: vector)
                                    try embed.insert(dbWriter)
                                }
                                print("🧠 Успешно сгенерирован и сохранен векторный эмбеддинг для кадра экрана #\(captureId)")
                            } catch {
                                print("❌ Ошибка сохранения семантического эмбеддинга кадра: \(error)")
                            }
                        }
                    }
                }
            }
            
            print("💾 Успешно сохранен кадр экрана и проиндексирован текст в локальной базе данных.")
            
        } catch {
            print("❌ Ошибка сохранения кадра экрана в БД: \(error)")
        }
    }
}
