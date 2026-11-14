import CoreMedia
import Foundation
import UIKit

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit

/// Native, full-resolution capture for iOS 27+.
///
/// ReplayKit's broadcast pipeline caps the long side at 1920 px, so a
/// 2796x1290 iPhone records at 886x1918. ScreenCaptureKit runs inside this
/// app instead of a 50 MB-capped extension, so it can deliver the display at
/// its native resolution.
///
/// Encoded video/audio still goes through the same `ScreenStreamer` ring
/// buffers and TCP servers the broadcast extension uses, so the desktop app
/// and relay keep working unchanged.
///
/// This path is compiled only when the build SDK contains ScreenCaptureKit
/// for iOS (Xcode 27+). Older SDKs skip it entirely and the broadcast
/// extension remains the only capture path.
@available(iOS 27.0, *)
@MainActor
final class ScreenCaptureController: NSObject, ObservableObject {
    static let shared = ScreenCaptureController()

    @Published private(set) var isRunning = false
    @Published private(set) var status = "Idle"
    @Published private(set) var lastError: String?

    private var stream: SCStream?
    private var streamer: ScreenStreamer?
    private var pendingConfiguration: SCStreamConfiguration?
    private let context = CIContext(options: [.cacheIntermediates: false])

    private let videoQueue = DispatchQueue(
        label: "screencapture.video", qos: .userInitiated
    )
    private let audioQueue = DispatchQueue(
        label: "screencapture.audio", qos: .userInitiated
    )

    /// Screens arrive at display rate; we encode at 30 fps so each frame gets
    /// twice the bits. Paced from buffer timestamps so it also works on
    /// 120 Hz ProMotion.
    private var lastEncodedPresentationTime = CMTime.invalid
    private let minimumFrameStep = CMTime(value: 1, timescale: 31)

    private override init() {
        super.init()
        SCContentSharingPicker.shared.add(self)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        lastError = nil
        status = "Choose the full display in the picker..."

        let configuration = makeConfiguration()
        pendingConfiguration = configuration

        let picker = SCContentSharingPicker.shared
        var pickerConfiguration = SCContentSharingPickerConfiguration()
        pickerConfiguration.showsMicrophoneControl = false
        pickerConfiguration.showsCameraControl = false
        picker.defaultConfiguration = pickerConfiguration
        picker.isActive = true
        picker.present()
    }

    func stop() {
        Task { await stopCapture() }
    }

    private func startStream(filter: SCContentFilter, configuration: SCStreamConfiguration) async {
        do {
            lastEncodedPresentationTime = .invalid
            let streamer = ScreenStreamer()
            try streamer.start(StreamerConfig(
                port: 12005,
                rect: CGRect.zero,
                scaleFactor: 1.0,
                qualityFactor: 1.0,
                expectedFrameRate: 30,
                averageBitRate: 50_000_000,
                isRealTime: true,
                audioPort: 12006,
                audioBitRate: 128_000
            ))

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()

            self.stream = stream
            self.streamer = streamer
            isRunning = true
            status = "Capturing \(configuration.width)x\(configuration.height) @ 30 fps"
            NSLog("[ScreenCapture] started \(configuration.width)x\(configuration.height)")
        } catch {
            teardown()
            lastError = error.localizedDescription
            status = "Failed: \(error.localizedDescription)"
            NSLog("[ScreenCapture] start failed: \(error)")
        }
    }

    private func stopCapture() async {
        if let stream {
            try? await stream.stopCapture()
        }
        teardown()
        SCContentSharingPicker.shared.isActive = false
        status = "Stopped"
    }

    private func teardown() {
        stream = nil
        streamer?.stop()
        streamer = nil
        isRunning = false
    }

    // MARK: - Configuration

    private func makeConfiguration() -> SCStreamConfiguration {
        let native = UIScreen.main.nativeBounds.size
        let longSide = Int(max(native.width, native.height))
        let shortSide = Int(min(native.width, native.height))

        // iOS exposes only width/height + audio on SCStreamConfiguration.
        // Frame interval and pixel format cannot be configured here, so the
        // stream delivers at display rate and we pace to 30 fps ourselves.
        let configuration = SCStreamConfiguration()
        configuration.width = longSide
        configuration.height = shortSide

        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        return configuration
    }

    enum CaptureError: LocalizedError {
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return "No display available to capture"
            }
        }
    }
}

// MARK: - Picker

@available(iOS 27.0, *)
extension ScreenCaptureController: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in
            guard let configuration = self.pendingConfiguration else { return }
            self.pendingConfiguration = nil
            await self.startStream(filter: filter, configuration: configuration)
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            self.pendingConfiguration = nil
            if !self.isRunning {
                self.status = "Picker cancelled"
            }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
            self.status = "Failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - SCStreamOutput

@available(iOS 27.0, *)
extension ScreenCaptureController: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        Task { @MainActor in
            switch type {
            case .screen:
                guard
                    let attachments = CMSampleBufferGetSampleAttachmentsArray(
                        sampleBuffer, createIfNecessary: false
                    ) as? [[SCStreamFrameInfo: Any]],
                    let rawStatus = attachments.first?[.status] as? Int,
                    let frameStatus = SCFrameStatus(rawValue: rawStatus),
                    frameStatus == .complete
                else {
                    return
                }

                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if self.lastEncodedPresentationTime.isValid {
                    let delta = CMTimeSubtract(pts, self.lastEncodedPresentationTime)
                    if CMTimeCompare(delta, self.minimumFrameStep) < 0 {
                        return
                    }
                }
                self.lastEncodedPresentationTime = pts

                self.streamer?.encode(
                    sampleBuffer: sampleBuffer,
                    context: self.context,
                    orientation: .up
                )
            case .audio:
                self.streamer?.encodeAudio(sampleBuffer: sampleBuffer)
            default:
                break
            }
        }
    }
}

// MARK: - SCStreamDelegate

@available(iOS 27.0, *)
extension ScreenCaptureController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
            self.status = "Stopped: \(error.localizedDescription)"
            self.teardown()
        }
    }
}

#endif
