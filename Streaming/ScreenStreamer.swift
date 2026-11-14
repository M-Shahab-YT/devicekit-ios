import CoreImage
import CoreMedia
import CoreVideo
import H264Codec
import OpusCodec
import UIKit

struct StreamerConfig {
    let port: UInt16
    let rect: CGRect
    let scaleFactor: Float
    let qualityFactor: Float
    let expectedFrameRate: Int
    let averageBitRate: Int
    let isRealTime: Bool
    let audioPort: UInt16?
    let audioBitRate: Int
}

final class ScreenStreamer {
    private let h264Encoder: H264Encoder
    private let audioEncoder: OpusAudioEncoder
    private let videoRing: RingStream
    private let audioRing: RingStream
    private var videoServer: RingServer?
    private var audioServer: RingServer?

    private var isPaused = false
    private var isStopped = false

    // Encoder is configured lazily from the first real video frame so we use the
    // frame's native dimensions (landscape when gaming) instead of a fixed rect.
    private var isConfigured = false
    private var configuredWidth: Int32 = 0
    private var configuredHeight: Int32 = 0
    private var failureCount = 0
    private var rebuildCount = 0
    private var scaleFactor: Float = 1.0
    private var expectedFrameRate: Int = 60
    private var averageBitRate: Int = 12_000_000
    private var qualityFactor: Float = 0.5
    private var isRealTime = true

    init(
        videoEncoder: H264Encoder = H264Encoder(),
        audioEncoder: OpusAudioEncoder = OpusAudioEncoder()
    ) {
        self.h264Encoder = videoEncoder
        self.audioEncoder = audioEncoder
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("DeviceKitRings", isDirectory: true)
        self.videoRing = RingStream(directory: root.appendingPathComponent("video", isDirectory: true))
        self.audioRing = RingStream(directory: root.appendingPathComponent("audio", isDirectory: true))
    }

    func start(_ config: StreamerConfig) throws {
        isPaused = false
        isStopped = false

        // New broadcast session: restart the on-disk rings at offset 0.
        videoRing.reset()
        audioRing.reset()

        scaleFactor = config.scaleFactor
        expectedFrameRate = config.expectedFrameRate
        averageBitRate = config.averageBitRate
        qualityFactor = config.qualityFactor
        isRealTime = config.isRealTime
        isConfigured = false

        let vServer = RingServer(port: config.port, ring: videoRing)
        try vServer.start()
        videoServer = vServer
        h264Encoder.naluHandling = { [weak self] data in
            guard let self else { return }
            // A keyframe NALU starts with SPS (0x67); remember where it began so
            // a viewer can be served from a decodable boundary.
            if data.count > 5,
               data[data.startIndex] == 0,
               data[data.startIndex + 1] == 0,
               data[data.startIndex + 2] == 1,
               data[data.startIndex + 3] == 0x67 {
                self.videoRing.markSyncPoint()
            } else if data.count > 6,
                      data[data.startIndex] == 0,
                      data[data.startIndex + 1] == 0,
                      data[data.startIndex + 2] == 0,
                      data[data.startIndex + 3] == 1,
                      data[data.startIndex + 4] == 0x67 {
                self.videoRing.markSyncPoint()
            }
            self.videoRing.append(data)
        }
        h264Encoder.errorHandling = { [weak self] status in
            self?.handleEncodeFailure(status)
        }
        h264Encoder.propertyFailureHandling = { key, status in
            diag("VT property rejected: \(key) -> \(status)")
        }

        if let audioPort = config.audioPort {
            audioEncoder.updateBitRate(config.audioBitRate)
            let aServer = RingServer(port: audioPort, ring: audioRing)
            try aServer.start()
            audioServer = aServer
            audioEncoder.opusHandling = { [weak self] data in
                guard let self else { return }
                self.audioRing.append(self.lengthPrefixed(data))
            }
        } else {
            audioEncoder.opusHandling = nil
            audioServer?.stop()
            audioServer = nil
        }
    }

    func encode(
        sampleBuffer: CMSampleBuffer,
        context: CIContext,
        orientation: CGImagePropertyOrientation
    ) {
        guard !isPaused, !isStopped else { return }
        let effective = effectiveOrientation(for: sampleBuffer, reported: orientation)
        ensureConfigured(for: sampleBuffer, orientation: effective)
        h264Encoder.encode(
            sampleBuffer: sampleBuffer,
            context: context,
            orientation: effective
        )
    }
    /// ReplayKit hands the extension the device's **native portrait** buffer and
    /// (on this iOS version) does not always provide `RPVideoSampleOrientationKey`.
    /// A landscape game therefore arrives as a portrait buffer whose content is
    /// rotated 90° clockwise. Detect that case and turn it back counter-clockwise
    /// so the encoded stream is upright landscape instead of sideways portrait.
    private func effectiveOrientation(
        for sampleBuffer: CMSampleBuffer,
        reported: CGImagePropertyOrientation
    ) -> CGImagePropertyOrientation {
        switch reported {
        case .left, .leftMirrored, .right, .rightMirrored:
            return reported
        default:
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return reported
            }
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            guard height > width else { return reported }

            // ReplayKit does not expose RPVideoSampleOrientationKey on this iOS
            // build, so the buffer is the native portrait frame with the
            // landscape game rotated inside it. The direction depends on which
            // landscape way the phone is held, which UIDevice tells us.
            let device = UIDevice.current.orientation
            let chosen: CGImagePropertyOrientation
            switch device {
            case .landscapeLeft:
                chosen = .left
            case .landscapeRight:
                chosen = .right
            default:
                chosen = .left
            }
            NSLog("[ScreenStreamer] rotate probe device=\(device.rawValue) buffer=\(width)x\(height) chosen=\(chosen.rawValue)")
            return chosen
        }
    }

    private func ensureConfigured(for sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sourceWidth = CVPixelBufferGetWidth(imageBuffer)
        let sourceHeight = CVPixelBufferGetHeight(imageBuffer)

        // A 90° rotation swaps the encoded dimensions. This is the case for a
        // landscape game delivered in the native portrait buffer.
        let swapsDimensions: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            swapsDimensions = true
        default:
            swapsDimensions = false
        }

        let baseWidth = swapsDimensions ? sourceHeight : sourceWidth
        let baseHeight = swapsDimensions ? sourceWidth : sourceHeight
        let width = Int32(Float(baseWidth) * scaleFactor)
        let height = Int32(Float(baseHeight) * scaleFactor)
        guard width > 0, height > 0 else { return }

        if isConfigured {
            guard width != configuredWidth || height != configuredHeight else { return }

            // VideoToolbox rejects buffers whose dimensions differ from the
            // session, and produces nothing at all. Games switch orientation
            // (portrait menu -> landscape match), so rebuild the session.
            diag("resolution changed \(configuredWidth)x\(configuredHeight) -> \(width)x\(height); reconfiguring")
            h264Encoder.invalidateCompressionSession()
            isConfigured = false
        }

        do {
            try h264Encoder.configureCompressSession(H264EncoderConfig(
                width: width,
                height: height,
                isRealTime: isRealTime,
                expectedFrameRate: expectedFrameRate,
                averageBitRate: averageBitRate,
                quality: qualityFactor
            ))
            isConfigured = true
            configuredWidth = width
            configuredHeight = height
            diag("encoder configured \(width)x\(height) @\(expectedFrameRate)fps \(averageBitRate)bps q\(qualityFactor) (source \(sourceWidth)x\(sourceHeight) rot=\(orientation.rawValue))")
        } catch {
            diag("encoder configure failed: \(error)")
        }
    }

    func encode(
        imageBuffer: CVImageBuffer,
        timestamp: CMTime,
        context: CIContext,
        orientation: CGImagePropertyOrientation
    ) {
        guard !isPaused, !isStopped else { return }
        h264Encoder.encode(
            imageBuffer: imageBuffer,
            timestamp: timestamp,
            context: context,
            orientation: orientation
        )
    }

    func encodeAudio(sampleBuffer: CMSampleBuffer) {
        guard !isPaused, !isStopped else { return }
        audioEncoder.encode(sampleBuffer: sampleBuffer)
    }

    func stop() {
        isStopped = true
        isConfigured = false
        videoServer?.stop()
        videoServer = nil
        audioServer?.stop()
        audioServer = nil
        h264Encoder.invalidateCompressionSession()
        audioEncoder.invalidate()
    }

    /// VideoToolbox can invalidate the session out from under us (kVTInvalidSessionErr
    /// = -12903), typically when a game grabs the GPU. Rebuild on the next frame
    /// instead of feeding a dead session forever.
    private func handleEncodeFailure(_ status: OSStatus) {
        guard status == -12903 else {
            failureCount += 1
            if failureCount % 60 == 1 {
                diag("VT encode failed: \(status) (n=\(failureCount))")
            }
            return
        }

        guard isConfigured else { return }
        isConfigured = false
        h264Encoder.invalidateCompressionSession()
        rebuildCount += 1
        diag("VT session invalidated (-12903); rebuilding session #\(rebuildCount)")
    }

    /// Total bytes appended to the video ring (diagnostics).
    var videoBytesWritten: UInt64 { videoRing.totalWritten }

    private func lengthPrefixed(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var packet = Data()
        packet.append(Data(bytes: &length, count: MemoryLayout.size(ofValue: length)))
        packet.append(data)
        return packet
    }
}
