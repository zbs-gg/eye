import Foundation
import Speech
import GRDB

public final class SlishuTranscriptionManager {
    public static let shared = SlishuTranscriptionManager()
    
    private let queue = DispatchQueue(label: "com.slishu.transcription.queue", qos: .utility)
    
    private init() {
        // Запрашиваем авторизацию для локального распознавания речи при запуске
        SFSpeechRecognizer.requestAuthorization { status in
            switch status {
            case .authorized:
                print("❇️ Локальное распознавание речи авторизовано")
            case .denied, .restricted, .notDetermined:
                print("⚠️ Локальное распознавание речи недоступно: статус \(status)")
            @unknown default:
                break
            }
        }
    }
    
    /// Помещение аудиофайла в очередь на транскрибацию
    public func enqueueTranscription(fileUrl: URL, timestamp: Date, duration: Double) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            print("🎙️ Получен аудио-чанк для распознавания: \(fileUrl.lastPathComponent)")
            
            // 1. Сначала сохраняем запись аудио в базу данных
            var audioCaptureId: Int64?
            let db = SlishuDatabase.shared
            let dbPool = db.getDatabasePool()
            
            do {
                try dbPool.write { dbWriter in
                    var audioRecord = SlishuAudioCapture(
                        timestamp: timestamp,
                        relativePath: fileUrl.lastPathComponent,
                        durationSeconds: duration
                    )
                    try audioRecord.insert(dbWriter)
                    audioCaptureId = audioRecord.id
                }
            } catch {
                print("❌ Ошибка сохранения аудиозаписи в БД: \(error)")
                return
            }
            
            guard let captureId = audioCaptureId else { return }
            
            // 2. Запускаем нативное локальное распознавание речи через SFSpeechRecognizer
            self.transcribeAudioNatively(fileUrl: fileUrl) { [weak self] transcribedText, language in
                guard let self = self else { return }
                
                let text = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    print("📝 Аудио-чанк \(fileUrl.lastPathComponent) не содержит речи.")
                    return
                }
                
                print("📝 Распознанный текст (\(language)): \"\(text)\"")
                
                // 3. Сохраняем расшифровку в БД и автоматически индексируем через FTS5
                do {
                    try dbPool.write { dbWriter in
                        var transcription = SlishuAudioTranscription(
                            audioCaptureId: captureId,
                            text: text,
                            language: language
                        )
                        try transcription.insert(dbWriter)
                    }
                    print("💾 Текст аудиозаписи успешно сохранен и проиндексирован в БД.")
                    
                    // Генерируем фоновый семантический эмбеддинг для аудиозаписи
                    Task.detached(priority: .background) {
                        if let vector = SlishuSemanticSearcher.shared.getEmbedding(for: text) {
                            do {
                                try dbPool.write { dbWriter in
                                    var embed = SlishuSemanticEmbedding(audioCaptureId: captureId, vector: vector)
                                    try embed.insert(dbWriter)
                                }
                                print("🧠 Успешно сгенерирован и сохранен векторный эмбеддинг для аудио чанка #\(captureId)")
                            } catch {
                                print("❌ Ошибка сохранения семантического эмбеддинга аудио: \(error)")
                            }
                        }
                    }
                } catch {
                    print("❌ Ошибка сохранения транскрипции в БД: \(error)")
                }
            }
        }
    }
    
    // MARK: - Локальное распознавание через SFSpeechRecognizer (Neural Engine)
    
    private func transcribeAudioNatively(fileUrl: URL, completion: @escaping (String, String) -> Void) {
        // Распознаем на русском языке, либо на английском в зависимости от системы
        let locales = [Locale(identifier: "ru-RU"), Locale(identifier: "en-US")]
        
        // Будем использовать первый доступный локальный распознаватель
        guard let recognizer = locales.compactMap({ locale -> SFSpeechRecognizer? in
            let rec = SFSpeechRecognizer(locale: locale)
            return (rec?.isAvailable == true) ? rec : nil
        }).first else {
            print("❌ Нативные локальные распознаватели речи недоступны")
            completion("", "unknown")
            return
        }
        
        let request = SFSpeechURLRecognitionRequest(url: fileUrl)
        request.requiresOnDeviceRecognition = true // Гарантируем 100% оффлайн на устройстве (Neural Engine)
        request.shouldReportPartialResults = false
        
        recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                print("❌ Ошибка SFSpeechRecognizer: \(error.localizedDescription)")
                completion("", recognizer.locale.identifier)
                return
            }
            
            if let result = result {
                if result.isFinal {
                    let text = result.bestTranscription.formattedString
                    completion(text, recognizer.locale.identifier)
                }
            }
        }
    }
}
