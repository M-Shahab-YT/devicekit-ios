import AVFAudio
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

    /// 80 Mbps VBR for 2796x1290 @ 30 fps (~0.75 bits/pixel). The QP cap is
    /// what actually buys sharpness; this ceiling just has to be high enough
    /// not to starve it on busy scenes.
    private static let averageBitRate = 60_000_000
    private static let frameRate = 30

    @Published private(set) var isRunning = false
    @Published private(set) var status = "Idle"
    @Published private(set) var lastError: String?

    /// Persisted: ScreenCaptureKit's landscape orientation depends on how the
    /// phone is held, so the user can flip the image 180 degrees.
    @Published var flip180: Bool = UserDefaults.standard.object(forKey: "sckFlip180v2") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(flip180, forKey: "sckFlip180v2")
            sink?.flip180 = flip180
        }
    }

    private var stream: SCStream?
    private var streamer: ScreenStreamer?
    private var sink: ScreenCaptureFrameSink?
    private var pendingConfiguration: SCStreamConfiguration?
    private var savedFilter: SCContentFilter?
    private var watchdog: Task<Void, Never>?
    private var recoveryAttempts = 0

    private override init() {
        super.init()
        SCContentSharingPicker.shared.add(self)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        lastError = nil
        status = "Choose the full display in the picker..."

        pendingConfiguration = makeConfiguration()

        var orientation = "unknown"
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            orientation = "\(scene.interfaceOrientation.rawValue)"
        }
        diag("start requested orientation=\(orientation) flip=\(flip180)")

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
        // Keep an audio session alive: ScreenCaptureKit's audio output needs the
        // app's audio session active, otherwise it delivers silent buffers.
        activateAudioSession()

        // Re-derive the size from the filter: the person may have started the
        // picker in portrait and rotated before choosing the display.
        var configuration = configuration
        let size = Self.outputSize()
        configuration.width = size.width
        configuration.height = size.height

        do {
            let streamer = ScreenStreamer()
            try streamer.start(StreamerConfig(
                port: 12005,
                rect: CGRect.zero,
                scaleFactor: 1.0,
                qualityFactor: 1.0,
                expectedFrameRate: Self.frameRate,
                averageBitRate: Self.averageBitRate,
                isRealTime: true,
                audioPort: 12006,
                audioBitRate: 128_000
            ))

            let sink = ScreenCaptureFrameSink(
                streamer: streamer,
                context: CIContext(options: [.cacheIntermediates: false]),
                flip180: self.flip180
            )

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.videoQueue)
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.audioQueue)
            try await stream.startCapture()

            self.stream = stream
            self.streamer = streamer
            self.sink = sink
            self.savedFilter = filter
            self.recoveryAttempts = 0
            isRunning = true
            status = "Capturing \(size.width)x\(size.height) @ \(Self.frameRate) fps"
            diag("started \(size.width)x\(size.height) @\(Self.frameRate)fps \(Self.averageBitRate)bps")
            startWatchdog()
        } catch {
            teardown()
            lastError = error.localizedDescription
            status = "Failed: \(error.localizedDescription)"
            diag("start failed: \(error.localizedDescription)")
        }
    }

    /// A stream can go silent without reporting an error (backgrounded too
    /// early, display asleep, occluded content). Rebuild it from the same
    /// filter so the PC side simply resumes, at most a few times.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.isRunning, let sink = self.sink else { continue }

                let frames = sink.encodedCount
                let bytes = self.streamer?.videoBytesWritten ?? 0
                diag("hb frames=\(frames) ring=\(bytes) silence=\(Int(sink.secondsSinceLastFrame)) tries=\(self.recoveryAttempts)")

                let silence = sink.secondsSinceLastFrame
                if silence < 2 {
                    self.recoveryAttempts = 0
                    continue
                }
                guard silence > 5, let filter = self.savedFilter else { continue }

                if self.recoveryAttempts >= 3 {
                    self.status = "No frames — check the screen is on and unlocked"
                    continue
                }
                self.recoveryAttempts += 1
                self.status = "No frames — restarting capture (\(self.recoveryAttempts)/3)…"
                diag("watchdog: \(Int(silence))s silence, restarting")
                await self.restartCapture(filter: filter)
            }
        }
    }

    private func restartCapture(filter: SCContentFilter) async {
        if let stream {
            try? await stream.stopCapture()
        }
        teardown()
        await startStream(filter: filter, configuration: makeConfiguration())
    }

    private func stopCapture() async {
        if let stream {
            try? await stream.stopCapture()
        }
        teardown()
        SCContentSharingPicker.shared.isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        status = "Stopped"
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            diag("audio session active")
        } catch {
            diag("audio session failed: \(error.localizedDescription)")
        }
    }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        sink = nil
        stream = nil
        streamer?.stop()
        streamer = nil
        isRunning = false
    }

    // MARK: - Configuration

    /// Native panel size in pixels, oriented the way the device is held.
    private static func outputSize() -> (width: Int, height: Int) {
        let native = UIScreen.main.nativeBounds.size
        let longSide = Int(max(native.width, native.height))
        let shortSide = Int(min(native.width, native.height))

        let landscape: Bool
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            landscape = scene.interfaceOrientation.isLandscape
        } else {
            landscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
        }
        return landscape ? (longSide, shortSide) : (shortSide, longSide)
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let size = Self.outputSize()

        // iOS exposes only width/height + audio on SCStreamConfiguration.
        // Frame interval and pixel format cannot be configured here (they are
        // macOS-only), so the stream delivers at display rate and the sink
        // paces to 30 fps itself.
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height

        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        return configuration
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
            diag("picker didUpdate: filter received, starting stream")
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

// MARK: - Stream delegate

@available(iOS 27.0, *)
extension ScreenCaptureController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        diag("stream stopped with error: \(error.localizedDescription)")
        Task { @MainActor in
            self.lastError = error.localizedDescription
            self.status = "Stopped: \(error.localizedDescription)"
            self.teardown()
        }
    }
}

/// Runs on the stream's sample queues, never on the main actor: at 60 fps a
/// per-frame hop to MainActor would allocate a Task per frame and could
/// reorder frames. ScreenCaptureKit calls each output queue serially.
@available(iOS 27.0, *)
final class ScreenCaptureFrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let videoQueue = DispatchQueue(label: "screencapture.video", qos: .userInitiated)
    let audioQueue = DispatchQueue(label: "screencapture.audio", qos: .userInitiated)

    private let streamer: ScreenStreamer
    private let context: CIContext

    private let stateLock = NSLock()
    private var lastEncodeTime: CFTimeInterval = 0
    private var lastFrameAt: CFTimeInterval = CACurrentMediaTime()
    private var skipped = 0
    private var encodedFrames = 0

    /// ScreenCaptureKit hands back the display in a fixed orientation. Holding
    /// the phone the other way yields a 180-degree rotated image, so the user
    /// can flip it here (persisted) instead of re-encoding on the PC.
    var flip180: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _flip180 }
        set { stateLock.lock(); _flip180 = newValue; stateLock.unlock() }
    }
    private var _flip180: Bool

    /// Target 30 fps, but never let the gate starve the pipeline.
    private let minimumInterval: CFTimeInterval = 1.0 / 31.0
    private let forcedFrameInterval: CFTimeInterval = 0.25
    private let maxConsecutiveSkips = 240

    private var didLogFirstFrame = false

    init(streamer: ScreenStreamer, context: CIContext, flip180: Bool) {
        self.streamer = streamer
        self.context = context
        self._flip180 = flip180
    }

    var secondsSinceLastFrame: CFTimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return CACurrentMediaTime() - lastFrameAt
    }

    var encodedCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return encodedFrames
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            encodeScreen(sampleBuffer)
        case .audio:
            streamer.encodeAudio(sampleBuffer: sampleBuffer)
        default:
            break
        }
    }

    private func encodeScreen(_ sampleBuffer: CMSampleBuffer) {
        // Skip frames the system marks idle/incomplete (occluded, resize).
        if
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let frameStatus = SCFrameStatus(rawValue: rawStatus),
            frameStatus != .complete
        {
            return
        }

        // Pace on a monotonic host clock, never on the buffer timestamp:
        // ScreenCaptureKit can repeat or rewind presentation times (idle
        // resend, stream restart), and a PTS-based gate then skips every
        // subsequent frame forever — the pipeline goes silent after the
        // first burst. Wall-clock pacing plus a forced frame keeps it alive.
        let now = CACurrentMediaTime()

        stateLock.lock()
        lastFrameAt = now
        let elapsed = now - lastEncodeTime
        let tooSoon = elapsed < minimumInterval
        skipped = tooSoon ? skipped + 1 : 0
        let mustForce = skipped >= maxConsecutiveSkips || elapsed >= forcedFrameInterval
        guard !tooSoon || mustForce else {
            stateLock.unlock()
            return
        }
        lastEncodeTime = now
        skipped = 0
        encodedFrames += 1
        stateLock.unlock()

        if !didLogFirstFrame, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            didLogFirstFrame = true
            diag("first frame \(CVPixelBufferGetWidth(imageBuffer))x\(CVPixelBufferGetHeight(imageBuffer))")
        }

        streamer.encode(
            sampleBuffer: sampleBuffer,
            context: context,
            orientation: flip180 ? .down : .up
        )
    }
}

#endif
