import Foundation
import PerchCore

/// User-facing notification switches backed by PerchConfig. The model lives
/// on the main actor so Notifier and SwiftUI always read one coherent value.
@MainActor
final class NotificationPreferences: ObservableObject {
    @Published var dangerousCalls: Bool { didSet { persist() } }
    @Published var attention: Bool { didSet { persist() } }
    @Published var taskCompletion: Bool { didSet { persist() } }
    @Published var usageThresholds: Bool { didSet { persist() } }
    @Published var sounds: Bool { didSet { persist() } }

    private var isInitializing = true

    init(config: PerchConfig = .load()) {
        dangerousCalls = config.notifyDangerousCalls
        attention = config.notifyAttention
        taskCompletion = config.notifyTaskCompletion
        usageThresholds = config.notifyUsageThresholds
        sounds = config.playNotificationSounds
        isInitializing = false
    }

    func markSetupCompleted() {
        var config = PerchConfig.load()
        guard !config.hasCompletedSetup else { return }
        config.hasCompletedSetup = true
        do {
            try config.save()
        } catch {
            PerchLog.warn("Could not save setup completion: \(error.localizedDescription)",
                          category: "config")
        }
    }

    private func persist() {
        guard !isInitializing else { return }
        var config = PerchConfig.load()
        config.notifyDangerousCalls = dangerousCalls
        config.notifyAttention = attention
        config.notifyTaskCompletion = taskCompletion
        config.notifyUsageThresholds = usageThresholds
        config.playNotificationSounds = sounds
        do {
            try config.save()
        } catch {
            PerchLog.warn("Could not save notification preferences: \(error.localizedDescription)",
                          category: "config")
        }
    }
}
