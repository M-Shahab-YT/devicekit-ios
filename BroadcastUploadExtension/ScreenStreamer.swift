import CoreImage
import CoreMedia
import CoreVideo
import H264Codec
import OpusCodec

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
    private let tcpServer: TCPServer
    private let audioEncoder: OpusAudioEncoder
    private let audioServer: TCPServer

    private var messageBuffer = Data()
    private var isPaused = false
    private var isStopped = false
    private var loggedMissingAudioClient = false

    // Encoder is configured lazily from the first real video frame so we use the
    // frame's native dimensions (landscape when gaming) instead of a fixed rect.
    private var isConfigured = false
    private var scaleFactor: Float = 1.0
    private var expectedFrameRate: Int = 60
    private var averageBitRate: Int = 12_000_000
    private var qualityFactor: Float = 0.5
    private var isRealTime = true

    init(
        videoEncoder: H264Encoder = H264Encoder(),
        tcpServer: TCPServer = TCPServer(),
        audioEncoder: OpusAudioEncoder = OpusAudioEncoder(),
        audioServer: TCPServer = TCPServer()
    ) {
        self.h264Encoder = videoEncoder
        self.tcpServer = tcpServer
        self.audioEncoder = audioEncoder
        self.audioServer = audioServer
    }

    func start(_ config: StreamerConfig) throws {
        isPaused = false
        isStopped = false

        try tcpServer.start(port: config.port)

        scaleFactor = config.scaleFactor
        expectedFrameRate = config.expectedFrameRate
        averageBitRate = config.averageBitRate
        qualityFactor = config.qualityFactor
        isRealTime = config.isRealTime
        isConfigured = false

        h264Encoder.naluHandling = { [weak self] data in
            guard let self else { return }
            tcpServer.dataHandler?(data)
        }

        if let audioPort = config.audioPort {
            audioEncoder.updateBitRate(config.audioBitRate)
            try audioServer.start(port: audioPort)
            audioEncoder.opusHandling = { [weak self] data in
                guard let self else { return }
                guard let dataHandler = audioServer.dataHandler else {
                    if !self.loggedMissingAudioClient {
                        self.loggedMissingAudioClient = true
                        NSLog("[ScreenStreamer] Opus frame ready but no audio client connected")
                    }
                    return
                }
                dataHandler(self.lengthPrefixed(data))
            }
        } else {
            audioEncoder.opusHandling = nil
            audioServer.stop()
        }

        tcpServer.messageHandler = { [weak self] data in
            guard let self else { return }
            self.handleIncomingData(data)
        }
    }

    private func handleIncomingData(_ data: Data) {
        messageBuffer.append(data)

        while messageBuffer.count >= 4 {
            let lengthBytes = messageBuffer.prefix(4)
            let length = Int(UInt32(bigEndian: lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))

            guard messageBuffer.count >= 4 + length else { break }

            let messageData = messageBuffer.subdata(in: 4..<(4 + length))
            messageBuffer.removeFirst(4 + length)

            handleJSONRPC(messageData)
        }
    }

    private func handleJSONRPC(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            print("[ScreenStreamer] Invalid JSON-RPC message")
            return
        }

        switch method {
        case "screencapture.setConfiguration":
            handleSetConfiguration(params: json["params"] as? [String: Any])
        case "screencapture.pause":
            handlePause()
        case "screencapture.resume":
            handleResume()
        case "screencapture.stop":
            handleStop()
        default:
            print("[ScreenStreamer] Unknown method: \(method)")
        }
    }

    private func handleSetConfiguration(params: [String: Any]?) {
        guard let params = params,
              let bitrate = params["bitrate"] as? Int else {
            print("[ScreenStreamer] Invalid params for setConfiguration")
            return
        }

        let frameRate = params["frameRate"] as? Int

        guard bitrate >= 100_000 && bitrate <= 8_000_000 else {
            print("[ScreenStreamer] Bitrate out of range: \(bitrate) (must be 100000-8000000)")
            return
        }

        if let fr = frameRate, fr < 1 || fr > 60 {
            print("[ScreenStreamer] Frame rate out of range: \(fr) (must be 1-60)")
            return
        }

        do {
            try h264Encoder.updateEncoderSettings(newBitrate: bitrate, newFrameRate: frameRate)
            print("[ScreenStreamer] ✓ Configuration updated: bitrate=\(bitrate) bps" +
                  (frameRate.map { ", frameRate=\($0)" } ?? ""))
        } catch {
            print("[ScreenStreamer] ✗ Failed to update encoder: \(error)")
        }
    }

    private func handlePause() {
        isPaused = true
        print("[ScreenStreamer] ✓ Paused")
    }

    private func handleResume() {
        isPaused = false
        print("[ScreenStreamer] ✓ Resumed")
    }

    private func handleStop() {
        stop()
        print("[ScreenStreamer] ✓ Stopped")
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
            return height > width ? .right : reported
        }
    }

    private func ensureConfigured(for sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        guard !isConfigured else { return }
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
            NSLog("[ScreenStreamer] source \(sourceWidth)x\(sourceHeight) orientation=\(orientation.rawValue) -> encoder \(width)x\(height) @\(expectedFrameRate)fps \(averageBitRate)bps q\(qualityFactor)")
        } catch {
            NSLog("[ScreenStreamer] encoder configure failed: \(error)")
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
        tcpServer.stop()
        h264Encoder.invalidateCompressionSession()
        audioServer.stop()
        audioEncoder.invalidate()
    }

    private func lengthPrefixed(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var packet = Data()
        packet.append(Data(bytes: &length, count: MemoryLayout.size(ofValue: length)))
        packet.append(data)
        return packet
    }
}
