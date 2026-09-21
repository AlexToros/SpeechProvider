@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum AudioSampleConverter {
    static let targetSampleRate = 16_000.0

    static func floats(from sampleBuffer: CMSampleBuffer) -> (samples: [Float], sampleRate: Double)? {
        guard
            sampleBuffer.isValid,
            CMSampleBufferDataIsReady(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else {
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        )

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let data = audioBufferList.mBuffers.mData else {
            return nil
        }

        let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)
        let isFloat = streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = streamDescription.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0

        if isFloat, streamDescription.mBitsPerChannel == 32 {
            let count = byteCount / MemoryLayout<Float>.stride
            let values = data.bindMemory(to: Float.self, capacity: count)
            return (Array(UnsafeBufferPointer(start: values, count: count)), streamDescription.mSampleRate)
        }

        if isSignedInteger, streamDescription.mBitsPerChannel == 16 {
            let count = byteCount / MemoryLayout<Int16>.stride
            let values = data.bindMemory(to: Int16.self, capacity: count)
            let scale = Float(Int16.max)
            return ((0..<count).map { Float(values[$0]) / scale }, streamDescription.mSampleRate)
        }

        return nil
    }

    static func makeMicrophoneConverter(inputFormat: AVAudioFormat) -> AVAudioConverter? {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }
        return AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) -> [Float]? {
        let ratio = targetSampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            ),
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }

        guard status != .error, error == nil, let channel = output.floatChannelData?[0] else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
