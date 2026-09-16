import Foundation
import PerchCore

/// User-facing notification switches backed by PerchConfig. The model lives
/// on the main actor so Notifier and SwiftUI always read one coherent value.
@MainActor
final class NotificationPreferences: ObservableObject {
    @Published var alertsDisabled: Bool { didSet { persist() } }
    @Published var dangerousCalls: Bool { didSet { persist() } }
    @Published var attention: Bool { didSet { persist() } }
    @Published var taskCompletion: Bool { didSet { persist() } }
    @Published var usageThresholds: Bool { didSet { persist() } }
    @Published var sounds: Bool { didSet { persist() } }

    private let loadConfig: () -> PerchConfig
    private let saveConfig: (PerchConfig) throws -> Void
    private var isInitializing = true

    init(config: PerchConfig? = nil,
         loadConfig: @escaping () -> PerchConfig = { .load() },
         saveConfig: @escaping (PerchConfig) throws -> Void = { try $0.save() }) {
        self.loadConfig = loadConfig
        self.saveConfig = saveConfig
        let config = config ?? loadConfig()
        alertsDisabled = config.alertsDisabled
        dangerousCalls = config.notifyDangerousCalls
        attention = config.notifyAttention
        taskCompletion = config.notifyTaskCompletion
        usageThresholds = config.notifyUsageThresholds
        sounds = config.playNotificationSounds
        isInitializing = false
    }

    func markSetupCompleted() {
        var config = loadConfig()
        guard !config.hasCompletedSetup else { return }
        config.hasCompletedSetup = true
        do {
            try saveConfig(config)
        } catch {
            PerchLog.warn("Could not save setup completion: \(error.localizedDescription)",
                          category: "config")
        }
    }

    private func persist() {
        guard !isInitializing else { return }
        var config = loadConfig()
        config.alertsDisabled = alertsDisabled
        config.notifyDangerousCalls = dangerousCalls
        config.notifyAttention = attention
        config.notifyTaskCompletion = taskCompletion
        config.notifyUsageThresholds = usageThresholds
        config.playNotificationSounds = sounds
        do {
            try saveConfig(config)
        } catch {
            PerchLog.warn("Could not save notification preferences: \(error.localizedDescription)",
                          category: "config")
        }
    }
}
