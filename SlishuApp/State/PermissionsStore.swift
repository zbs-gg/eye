import Foundation
import Observation

@MainActor
@Observable
final class PermissionsStore {
    private(set) var snapshot = PermissionSnapshot()

    /// SCK вернул ошибку при ВЫДАННОМ праве (классика -3801 после выдачи Screen Recording: TCC требует
    /// перезапуск процесса). Ставится из capture-цикла; сбрасывается только рестартом приложения.
    private(set) var screenNeedsRestart = false

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    func refreshAll() async {
        var snap = PermissionChecker.snapshot()
        // право выдано, но захват фактически падает → честный статус «нужен перезапуск»
        if screenNeedsRestart && snap.screenRecording == .granted {
            snap.screenRecording = .needsRestart
        }
        snapshot = snap
    }

    /// Капчур упёрся в SCK-отказ при granted-праве — поднять needsRestart (UI покажет «Перезапуск»).
    func flagScreenNeedsRestart() {
        guard !screenNeedsRestart else { return }
        screenNeedsRestart = true
        Task { await refreshAll() }
    }

    /// Захват восстановился (сбой был транзиентным: wake, смена мониторов) — снять ratchet, иначе
    /// «Нужен перезапуск» и блок повторного старта висели бы до релонча при живом захвате.
    func clearScreenNeedsRestart() {
        guard screenNeedsRestart else { return }
        screenNeedsRestart = false
        Task { await refreshAll() }
    }

    /// Фоновый поллинг прав: юзер выдаёт права в Системных настройках — UI подхватывает без «Повторить
    /// проверку». Дёшево (TCC-пробы — локальные вызовы). Стартует один раз из bootstrap.
    func startPolling(interval: TimeInterval = 3) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.refreshAll()
            }
        }
    }

    /// Критичные для записи права: экран + accessibility (микрофон/речь — для аудио, опциональны).
    var allCriticalGranted: Bool {
        snapshot.screenRecording == .granted && snapshot.accessibility == .granted
    }

    func requestMicrophone() async {
        await PermissionChecker.requestMicrophone()
        await refreshAll()
    }

    func requestSpeech() async {
        await PermissionChecker.requestSpeech()
        await refreshAll()
    }
}
