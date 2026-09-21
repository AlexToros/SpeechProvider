@preconcurrency import ScreenCaptureKit
import CoreMedia
import Foundation

final class SystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputQueue = DispatchQueue(label: "speechprovider.system-audio", qos: .userInteractive)
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var stream: SCStream?

    func chunks() -> AsyncStream<AudioChunk> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func availableSources() async throws -> [AudioSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let applications = content.applications
            .filter { $0.processID != ProcessInfo.processInfo.processIdentifier }
            .map {
                AudioSource.application(
                    processID: $0.processID,
                    name: $0.applicationName,
                    bundleIdentifier: $0.bundleIdentifier
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return [.system] + applications
    }

    func start(source: AudioSource) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter: SCContentFilter
        switch source {
        case .system:
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case let .application(processID, _, _):
            guard let application = content.applications.first(where: { $0.processID == processID }) else {
                throw CaptureError.applicationUnavailable
            }
            filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        }

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.capturesAudio = true
        configuration.sampleRate = Int(AudioSampleConverter.targetSampleRate)
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard
            outputType == .audio,
            let converted = AudioSampleConverter.floats(from: sampleBuffer),
            !converted.samples.isEmpty
        else {
            return
        }

        let chunk = AudioChunk(
            speaker: .remote,
            samples: converted.samples,
            sampleRate: converted.sampleRate,
            capturedAt: Date()
        )
        _ = lock.withLock {
            continuation?.yield(chunk)
        }
    }
}
