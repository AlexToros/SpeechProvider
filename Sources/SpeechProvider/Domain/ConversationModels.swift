import Foundation

enum Speaker: String, Codable, Sendable {
    case local
    case remote
}

enum ConversationLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case spanish = "es"
    case german = "de"
    case french = "fr"
    case italian = "it"
    case portuguese = "pt"
    case turkish = "tr"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case russian = "ru"

    var id: Self { self }

    var title: String {
        switch self {
        case .english: "Английский"
        case .spanish: "Испанский"
        case .german: "Немецкий"
        case .french: "Французский"
        case .italian: "Итальянский"
        case .portuguese: "Португальский"
        case .turkish: "Турецкий"
        case .chinese: "Китайский"
        case .japanese: "Японский"
        case .korean: "Корейский"
        case .russian: "Русский"
        }
    }

    static var systemDefault: Self {
        let preferredLocale = Locale.preferredLanguages.first ?? Locale.current.identifier
        return systemLanguage(for: preferredLocale)
    }

    static func systemLanguage(for localeIdentifier: String) -> Self {
        let languageCode = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        return languageCode.flatMap(Self.init(rawValue:)) ?? .russian
    }
}

struct Utterance: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let speaker: Speaker
    let startedAt: Date
    let endedAt: Date
    let originalText: String
    let detectedLanguage: String
    let languageConfidence: Float
    var russianText: String?

    init(
        id: UUID = UUID(),
        speaker: Speaker,
        startedAt: Date,
        endedAt: Date,
        originalText: String,
        detectedLanguage: String,
        languageConfidence: Float,
        russianText: String? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.originalText = originalText
        self.detectedLanguage = detectedLanguage
        self.languageConfidence = languageConfidence
        self.russianText = russianText
    }

}

struct Transcription: Equatable, Sendable {
    let text: String
    let language: String
    let languageConfidence: Float
}

struct ReplySuggestion: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let targetText: String
    let russianMeaning: String
    let tone: String

    init(
        id: UUID = UUID(),
        targetText: String,
        russianMeaning: String,
        tone: String
    ) {
        self.id = id
        self.targetText = targetText
        self.russianMeaning = russianMeaning
        self.tone = tone
    }
}

struct ConversationMemory: Codable, Equatable, Sendable {
    var summary = ""
    var facts: [String] = []
    var decisions: [String] = []
    var openQuestions: [String] = []
    var commitments: [String] = []
    var glossary: [String: String] = [:]
    var tone = ""
    var lastIntent = ""
    var coveredThroughUtteranceID: UUID?
}
