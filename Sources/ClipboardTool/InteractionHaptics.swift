import AppKit

/// System-managed Force Touch feedback; unsupported pointing devices simply ignore it.
enum InteractionHaptics {
    private static var lastFeedback: TimeInterval = 0
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard Thread.isMainThread else { return }
        guard UserDefaults.standard.object(forKey: "interaction.haptics") as? Bool ?? true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFeedback > 0.12 else { return }
        lastFeedback = now
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
