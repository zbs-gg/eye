import Foundation

extension AudioSettingsStore {
    func refreshHealth(_ audio: AudioCoordinator?) async {
        health = await audio?.health()
        micEngineFailed = audio?.micStartFailed ?? false
    }
}
