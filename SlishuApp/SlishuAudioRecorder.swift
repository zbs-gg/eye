import Foundation
import AVFoundation

public final class SlishuAudioRecorder: NSObject {
    public static let shared = SlishuAudioRecorder()
    
    private let queue = DispatchQueue(label: "com.slishu.audio.recorder.queue", qos: .userInitiated)
    private var audioEngine: AVAudioEngine?
    private var currentAudioFile: AVAudioFile?
    private var currentAudioFileUrl: URL?
    private var chunkStartTime: Date?
    
    // Интервал чанка (30 секунд)
    private let chunkDuration: TimeInterval = 30.0
    private var chunkTimer: DispatchSourceTimer?
    
    private var isRecording = false
    
    private override init() {
        super.init()
        setupConfigurationChangeObserver()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - API управления
    
    public func startRecording() {
        queue.async { [weak self] in
            guard let self = self, !self.isRecording else { return }
            self.isRecording = true
            
            print("🎙️ Запуск фоновой аудиозаписи через AVAudioEngine...")
            self.startMicrophoneCapture()
            
            // Запускаем DispatchSourceTimer на фоновой последовательной очереди
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.chunkDuration, repeating: self.chunkDuration)
            timer.setEventHandler { [weak self] in
                self?.rotateChunk()
            }
            timer.resume()
            self.chunkTimer = timer
        }
    }
    
    public func stopRecording() {
        queue.async { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.isRecording = false
            
            self.chunkTimer?.cancel()
            self.chunkTimer = nil
            
            self.stopMicrophoneCapture()
            self.finalizeCurrentChunk()
            
            print("🎙️ Фоновая аудиозапись остановлена")
        }
    }
    
    // MARK: - Захват микрофона через AVAudioEngine
    
    private func startMicrophoneCapture() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Настройка первого чанка
        self.setupNewChunk(format: inputFormat)
        
        // Подключаем tap для получения PCM буферов микрофона и записи их в файл
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            
            // Жестко захватываем целевой файл СИНХРОННО под очередью, чтобы при
            // ротации чанков кадры не смешались в новый файл
            guard let targetFile = self.queue.sync(execute: { self.currentAudioFile }) else { return }
            
            self.queue.async {
                guard self.isRecording else { return }
                do {
                    try targetFile.write(from: buffer)
                } catch {
                    print("❌ Ошибка записи аудио-буфера в файл: \(error)")
                }
            }
        }
        
        do {
            try engine.start()
            self.audioEngine = engine
            print("🎙️ Захват микрофона успешно запущен через AVAudioEngine")
        } catch {
            print("❌ Не удалось запустить AVAudioEngine: \(error)")
        }
    }
    
    private func stopMicrophoneCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }
    
    // MARK: - Управление чанками (файлами по 30 сек)
    
    private func setupNewChunk(format: AVAudioFormat) {
        let db = SlishuDatabase.shared
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let filename = "audio_\(formatter.string(from: Date())).m4a"
        let fileUrl = db.mediaDirectory.appendingPathComponent(filename)
        
        do {
            // Настраиваем аппаратное сжатие в AAC на частоте 16 кГц моно (битрейт 64 kbps)
            // Это экономит ~98% дискового пространства по сравнению с сырым PCM!
            var settings = [String: Any]()
            settings[AVFormatIDKey] = Int(kAudioFormatMPEG4AAC)
            settings[AVSampleRateKey] = 16000.0
            settings[AVNumberOfChannelsKey] = 1
            settings[AVEncoderBitRateKey] = 64000
            
            // Используем инициализатор с авто-конверсией PCM буферов на лету
            let audioFile = try AVAudioFile(
                forWriting: fileUrl,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            
            self.currentAudioFileUrl = fileUrl
            self.currentAudioFile = audioFile
            self.chunkStartTime = Date()
            
            print("📝 Начата запись нового аудио-чанка: \(filename)")
        } catch {
            print("❌ Ошибка создания AVAudioFile: \(error)")
        }
    }
    
    private func rotateChunk() {
        // Метод гарантированно выполняется на фоновой queue таймера
        guard self.isRecording, let engine = self.audioEngine else { return }
        
        // Финализируем текущий чанк
        self.finalizeCurrentChunk()
        
        // Открываем новый чанк с тем же аудио-форматом
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        self.setupNewChunk(format: inputFormat)
    }
    
    private func finalizeCurrentChunk() {
        guard let url = currentAudioFileUrl, let startTime = chunkStartTime else { return }
        
        // Закрываем файл
        currentAudioFile = nil
        currentAudioFileUrl = nil
        chunkStartTime = nil
        
        print("💾 Аудио-чанк успешно сохранен и закрыт: \(url.lastPathComponent)")
        
        // Передаем файл в менеджер транскрибации Whisper
        let duration = chunkDuration
        SlishuTranscriptionManager.shared.enqueueTranscription(fileUrl: url, timestamp: startTime, duration: duration)
    }
    
    // MARK: - Подписка на уведомления изменений оборудования
    
    private func setupConfigurationChangeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }
    
    @objc private func handleEngineConfigurationChange() {
        queue.async { [weak self] in
            guard let self = self, self.isRecording else { return }
            print("🔊 Системная конфигурация аудио изменилась (sample rate, AirPods и т.д.). Перезапуск AVAudioEngine...")
            
            self.stopMicrophoneCapture()
            self.startMicrophoneCapture()
        }
    }
}
