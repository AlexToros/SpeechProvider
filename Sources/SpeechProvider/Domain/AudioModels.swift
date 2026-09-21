import Foundation

struct AudioChunk: Sendable {
    let speaker: Speaker
    let samples: [Float]
    let sampleRate: Double
    let capturedAt: Date
}

struct AudioSegment: Sendable {
    let speaker: Speaker
    let samples: [Float]
    let sampleRate: Double
    let startedAt: Date
    let endedAt: Date
}

enum AudioSource: Hashable, Identifiable, Sendable {
    case system
    case application(processID: Int32, name: String, bundleIdentifier: String?)

    var id: String {
        switch self {
        case .system:
            "system"
        case let .application(processID, _, _):
            "application-\(processID)"
        }
    }

    var title: String {
        switch self {
        case .system:
            "Весь системный звук"
        case let .application(_, name, _):
            name
        }
    }
}
