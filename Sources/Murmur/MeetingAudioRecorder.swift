import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct MeetingAudioArtifacts {
    let system: [URL]
    let microphone: [URL]
}

private final class ChunkedAudioSink: @unchecked Sendable {
    private let directory: URL
    private let prefix: String
    private let queue: DispatchQueue
    private let chunkFrames: AVAudioFramePosition
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var chunkIndex = 0
    private(set) var urls: [URL] = []

    init(directory: URL, prefix: String, chunkSeconds: Double = 300) {
        self.directory = directory
        self.prefix = prefix
        self.queue = DispatchQueue(label: "ai.murmur.meeting.\(prefix)")
        self.chunkFrames = AVAudioFramePosition(chunkSeconds * 16_000)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in self?.write(sampleBuffer) }
    }

    func close() -> [URL] {
        queue.sync {
            file = nil
            return urls
        }
    }

    private func write(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: asbd) else { return }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return }

        let sourceList = AudioBufferList.allocate(maximumBuffers: max(1, Int(inputFormat.channelCount)))
        var retained: CMBlockBuffer?
        let size = AudioBufferList.sizeInBytes(maximumBuffers: max(1, Int(inputFormat.channelCount)))
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: sourceList.unsafeMutablePointer,
            bufferListSize: size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retained)
        guard status == noErr else { free(sourceList.unsafeMutablePointer); return }
        let retainedBlock = retained
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                            bufferListNoCopy: sourceList.unsafePointer,
                                            deallocator: { _ in
                                                _ = retainedBlock
                                                free(sourceList.unsafeMutablePointer)
                                            }) else {
            free(sourceList.unsafeMutablePointer)
            return
        }
        input.frameLength = frames

        do {
            if format == nil { format = inputFormat }
            if file == nil || framesWritten >= chunkFrames {
                try openChunk(format: inputFormat)
            }
            try file?.write(from: input)
            framesWritten += AVAudioFramePosition(frames)
        } catch {
            Log.error("meeting \(prefix) write failed: \(error.localizedDescription)")
        }
    }

    private func openChunk(format: AVAudioFormat) throws {
        file = nil
        framesWritten = 0
        chunkIndex += 1
        let url = directory.appendingPathComponent(String(format: "%@-%04d.caf", prefix, chunkIndex))
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        urls.append(url)
    }
}

final class MeetingAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var systemSink: ChunkedAudioSink?
    private var microphoneSink: ChunkedAudioSink?
    private let systemQueue = DispatchQueue(label: "ai.murmur.meeting.system-output")
    private let microphoneQueue = DispatchQueue(label: "ai.murmur.meeting.microphone-output")

    func start(directory: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "Murmur.MeetingRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for system audio capture"])
        }
        let ownID = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { $0.bundleIdentifier == ownID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1

        let system = ChunkedAudioSink(directory: directory, prefix: "system")
        let microphone = ChunkedAudioSink(directory: directory, prefix: "microphone")
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
        lock.withLock {
            self.systemSink = system
            self.microphoneSink = microphone
            self.stream = stream
        }
        do { try await stream.startCapture() }
        catch {
            _ = finishSinks()
            throw error
        }
        Log.info("meeting dual-track capture started")
    }

    func stop() async -> MeetingAudioArtifacts {
        let active = lock.withLock { () -> SCStream? in
            let value = stream
            stream = nil
            return value
        }
        if let active { try? await active.stopCapture() }
        let artifacts = finishSinks()
        Log.info("meeting capture stopped: \(artifacts.system.count) system, \(artifacts.microphone.count) mic chunks")
        return artifacts
    }

    private func finishSinks() -> MeetingAudioArtifacts {
        let sinks = lock.withLock { () -> (ChunkedAudioSink?, ChunkedAudioSink?) in
            let value = (systemSink, microphoneSink)
            systemSink = nil
            microphoneSink = nil
            return value
        }
        return MeetingAudioArtifacts(system: sinks.0?.close() ?? [], microphone: sinks.1?.close() ?? [])
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.error("meeting stream stopped: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        switch outputType {
        case .audio: lock.withLock { systemSink }?.append(sampleBuffer)
        case .microphone: lock.withLock { microphoneSink }?.append(sampleBuffer)
        default: break
        }
    }
}
