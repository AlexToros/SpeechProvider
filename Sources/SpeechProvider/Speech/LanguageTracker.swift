import Foundation

actor LanguageTracker {
    struct Configuration: Sendable {
        var confirmationsRequired = 2
        var minimumConfidence: Float = 0.35
    }

    private struct State {
        var stableLanguage: String?
        var candidateLanguage: String?
        var confirmations = 0
    }

    private let configuration: Configuration
    private var states: [Speaker: State] = [:]

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func language(
        for speaker: Speaker,
        detected: String,
        confidence: Float
    ) -> String {
        var state = states[speaker, default: State()]
        guard detected != "und", confidence >= configuration.minimumConfidence else {
            return state.stableLanguage ?? detected
        }

        if state.stableLanguage == nil {
            state.stableLanguage = detected
        } else if state.candidateLanguage == detected {
            state.confirmations += 1
            if state.confirmations >= configuration.confirmationsRequired {
                state.stableLanguage = detected
                state.candidateLanguage = nil
                state.confirmations = 0
            }
        } else if state.stableLanguage != detected {
            state.candidateLanguage = detected
            state.confirmations = 1
        } else {
            state.candidateLanguage = nil
            state.confirmations = 0
        }

        states[speaker] = state
        return state.stableLanguage ?? detected
    }

    func lastRemoteLanguage() -> String? {
        states[.remote]?.stableLanguage
    }

    func resetConversation() {
        states.removeAll(keepingCapacity: true)
    }
}
