import CoreImage
import CoreMedia
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
    // Must match devicekit-android AvcServer's MIN_BITRATE/MAX_BITRATE and
    // webrtc-server's GCC SendSideBWEMaxBitrate cap.
    private static let minBitrate = 100_000
    private static let maxBitrate = 10_000_000

    private let h264Encoder: H264Encoder
    private let tcpServer: TCPServer
    private let audioEncoder: OpusAudioEncoder
    private let audioServer: TCPServer

    private var messageBuffer = Data()
    private var isPaused = false
    private var isStopped = false
    private var loggedMissingAudioClient = false

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

        let dimensions = config.rect.scaledDimensions(config.scaleFactor)
        try h264Encoder.configureCompressSession(H264EncoderConfig(
            width: dimensions.width,
            height: dimensions.height,
            isRealTime: config.isRealTime,
            expectedFrameRate: config.expectedFrameRate,
            averageBitRate: config.averageBitRate,
            quality: config.qualityFactor
        ))

        h264Encoder.naluHandling = { [weak self] data in
            guard let self else { return }
            tcpServer.dataHandler?(data)
        }

        // A client connecting on a static screen would otherwise wait for the
        // next screen change (ReplayKit delivers no samples until then) before
        // it ever sees a keyframe — re-encode the last frame as IDR right away.
        tcpServer.onClientConnected = { [weak self] in
            self?.h264Encoder.reencodeLastFrameAsKeyFrame()
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
        case "screencapture.setBitrate":
            handleSetBitrate(params: json["params"] as? [String: Any])
        case "screencapture.requestKeyFrame":
            h264Encoder.reencodeLastFrameAsKeyFrame()
            print("[ScreenStreamer] ✓ Requested immediate key frame")
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

    // Same method name, param, and clamp behavior as devicekit-android's
    // AvcServer control channel, so mobilecli sends one payload for both
    // platforms. Out-of-range values clamp rather than reject — the REMB
    // control loop may legitimately ask for more than the encoder ceiling.
    private func handleSetBitrate(params: [String: Any]?) {
        guard let bps = params?["bps"] as? Int, bps > 0 else {
            print("[ScreenStreamer] setBitrate requires a positive 'bps'")
            return
        }

        let clamped = min(max(bps, Self.minBitrate), Self.maxBitrate)

        do {
            try h264Encoder.updateEncoderSettings(newBitrate: clamped)
            print("[ScreenStreamer] ✓ Applied live bitrate: \(clamped) bps")
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
        h264Encoder.encode(
            sampleBuffer: sampleBuffer,
            context: context,
            orientation: orientation
        )
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
