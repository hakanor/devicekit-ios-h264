import Accelerate
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox

public struct H264EncoderConfig {
    public let width: Int32
    public let height: Int32
    public let isRealTime: Bool
    public let expectedFrameRate: Int
    public let averageBitRate: Int
    public let quality: Float

    public init(
        width: Int32,
        height: Int32,
        isRealTime: Bool,
        expectedFrameRate: Int,
        averageBitRate: Int,
        quality: Float
    ) {
        self.width = width
        self.height = height
        self.isRealTime = isRealTime
        self.expectedFrameRate = expectedFrameRate
        self.averageBitRate = averageBitRate
        self.quality = quality
    }
}

public final class H264Encoder: NSObject {
    enum ConfigurationError: Error {
        case cannotCreateSession
        case cannotSetProperties
        case cannotPrepareToEncode
    }

    private var session: VTCompressionSession?
    private var pendingForceKeyFrame = false

    // Last frame handed to the encoder, kept so a newly connected client can get
    // a keyframe immediately. ReplayKit only delivers samples when the screen
    // changes, so on a static screen "force keyframe on next frame" would never
    // fire — re-encoding the last frame is the only way to guarantee a decodable
    // first frame. Guarded by lastFrameLock: written from ReplayKit's sample
    // thread, read from the TCP connection queue.
    private let lastFrameLock = NSLock()
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastPresentationTimeStamp = CMTime.invalid
    private var lastDuration = CMTime.invalid

    private static let naluStartCode = Data([UInt8](arrayLiteral: 0x00, 0x00, 0x00, 0x01))

    // uuid for timing SEI (user data unregistered)
    private static let timingUUID: [UInt8] = [
        0x4D, 0x4F, 0x42, 0x49, 0x4C, 0x45, 0x4E, 0x58,  // "MOBILENX"
        0x54, 0x49, 0x4D, 0x45, 0x43, 0x4F, 0x44, 0x45   // "TIMECODE"
    ]

    public var naluHandling: ((Data) -> Void)?

    public func configureCompressSession(_ config: H264EncoderConfig) throws {
        let error = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: config.width,
            height: config.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: encodingOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard error == errSecSuccess,
              let session = session else {
            throw ConfigurationError.cannotCreateSession
        }

        let propertyDictionary = [
            kVTCompressionPropertyKey_PixelTransferProperties: [
                kVTPixelTransferPropertyKey_ScalingMode: kVTScalingMode_Normal
            ],
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: config.expectedFrameRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: config.expectedFrameRate,
            kVTCompressionPropertyKey_AverageBitRate: config.averageBitRate,
            kVTCompressionPropertyKey_RealTime: config.isRealTime,
            kVTCompressionPropertyKey_MaximizePowerEfficiency: true,
            kVTCompressionPropertyKey_Quality: config.quality
        ] as CFDictionary

        guard VTSessionSetProperties(session, propertyDictionary: propertyDictionary) == noErr else {
            throw ConfigurationError.cannotSetProperties
        }

        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            throw ConfigurationError.cannotPrepareToEncode
        }

        print("VTCompressSession is ready to use")
    }

    public func updateEncoderSettings(newBitrate: Int, newFrameRate: Int? = nil) throws {
        guard let session = session else {
            throw ConfigurationError.cannotSetProperties
        }

        var propertyDict: [CFString: Any] = [
            kVTCompressionPropertyKey_AverageBitRate: newBitrate
        ]

        if let frameRate = newFrameRate {
            propertyDict[kVTCompressionPropertyKey_ExpectedFrameRate] = frameRate
            propertyDict[kVTCompressionPropertyKey_MaxKeyFrameInterval] = frameRate
        }

        let cfDict = propertyDict as CFDictionary
        guard VTSessionSetProperties(session, propertyDictionary: cfDict) == noErr else {
            throw ConfigurationError.cannotSetProperties
        }

        print("[H264Encoder] Updated settings: bitrate=\(newBitrate) bps" +
              (newFrameRate.map { ", frameRate=\($0)" } ?? ""))
    }

    public func forceNextKeyFrame() {
        pendingForceKeyFrame = true
    }

    /// Re-encodes the most recent frame as a keyframe right now, so a client
    /// that connects while the screen is static still receives SPS/PPS+IDR
    /// instead of waiting for the next screen change. Falls back to forcing the
    /// next real frame when nothing has been encoded yet.
    public func reencodeLastFrameAsKeyFrame() {
        forceNextKeyFrame()

        lastFrameLock.lock()
        let pixelBuffer = lastPixelBuffer
        let lastPTS = lastPresentationTimeStamp
        let duration = lastDuration
        lastFrameLock.unlock()

        guard let session, let pixelBuffer, lastPTS.isValid else { return }

        // PTS must keep increasing. ReplayKit stamps frames with the host clock,
        // so "now" is safe; the max() guards against reconnects within one frame.
        let step = duration.isValid && duration.value > 0 ? duration : CMTime(value: 1, timescale: 30)
        let pts = CMTimeMaximum(CMClockGetTime(CMClockGetHostTimeClock()), CMTimeAdd(lastPTS, step))

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nextFrameProperties(),
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        rememberLastFrame(pixelBuffer, presentationTimeStamp: pts, duration: duration)
    }

    private func rememberLastFrame(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime, duration: CMTime) {
        lastFrameLock.lock()
        lastPixelBuffer = pixelBuffer
        lastPresentationTimeStamp = presentationTimeStamp
        lastDuration = duration
        lastFrameLock.unlock()
    }

    public func invalidateCompressionSession() {
        guard let session = session else {
            return
        }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        lastFrameLock.lock()
        lastPixelBuffer = nil
        lastPresentationTimeStamp = .invalid
        lastFrameLock.unlock()
    }

    // swiftlint:disable closure_parameter_position
    private var encodingOutputCallback: VTCompressionOutputCallback = { (
        outputCallbackRefCon: UnsafeMutableRawPointer?,
        _: UnsafeMutableRawPointer?,
        status: OSStatus,
        flags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) in
    // swiftlint:enable closure_parameter_position
        guard let sampleBuffer = sampleBuffer else {
            print("nil buffer")
            return
        }
        guard let refcon: UnsafeMutableRawPointer = outputCallbackRefCon else {
            print("nil pointer")
            return
        }
        guard status == noErr else {
            print("encoding failed")
            return
        }
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            print("CMSampleBuffer is not ready to use")
            return
        }
        guard flags != VTEncodeInfoFlags.frameDropped else {
            print("frame dropped")
            return
        }

        let encoder: H264Encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()

        if sampleBuffer.isKeyFrame {
            encoder.extractSPSAndPPS(from: sampleBuffer)
        }

        var dataBuffer: CMBlockBuffer?
        if #available(iOS 13.0, *) {
            dataBuffer = sampleBuffer.dataBuffer
        } else {
            dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        }
        guard let dataBuffer = dataBuffer else { return }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let error = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard error == kCMBlockBufferNoErr,
              let dataPointer = dataPointer else { return }

        // emit a timing SEI before the frame's VCL NAL units
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid {
            encoder.naluHandling?(H264Encoder.createTimingSEI(pts: pts))
        }

        var packageStartIndex = 0

        while packageStartIndex < totalLength {
            var nextNALULength: UInt32 = 0
            memcpy(&nextNALULength, dataPointer.advanced(by: packageStartIndex), 4)
            nextNALULength = CFSwapInt32BigToHost(nextNALULength)
            guard packageStartIndex + 4 + Int(nextNALULength) <= totalLength else { break }

            let naluLength = Int(nextNALULength)
            var naluData = Data(capacity: 4 + naluLength)
            naluData.append(naluStartCode)
            dataPointer.advanced(by: packageStartIndex + 4)
                .withMemoryRebound(to: UInt8.self, capacity: naluLength) { ptr in
                    naluData.append(ptr, count: naluLength)
                }

            packageStartIndex += (4 + naluLength)

            encoder.naluHandling?(naluData)
        }
    }

    public func encode(
        sampleBuffer: CMSampleBuffer,
        context: CIContext,
        orientation: CGImagePropertyOrientation
    ) {
        guard let session = session,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let rotatedPixelBuffer = imageBuffer.rotate(context: context, orientation: orientation)
        else {
            return
        }

        let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: rotatedPixelBuffer,
            presentationTimeStamp: timeStamp,
            duration: duration,
            frameProperties: nextFrameProperties(),
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        rememberLastFrame(rotatedPixelBuffer, presentationTimeStamp: timeStamp, duration: duration)
    }

    public func encode(
        imageBuffer: CVImageBuffer,
        timestamp: CMTime,
        context: CIContext,
        orientation: CGImagePropertyOrientation
    ) {
        guard let session = session,
              let rotatedPixelBuffer = imageBuffer.rotate(context: context, orientation: orientation)
        else {
            return
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: rotatedPixelBuffer,
            presentationTimeStamp: timestamp,
            duration: CMTime.invalid,
            frameProperties: nextFrameProperties(),
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        rememberLastFrame(rotatedPixelBuffer, presentationTimeStamp: timestamp, duration: .invalid)
    }

    public func encode(
        pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        guard let session = session else { return }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: CMTime.invalid,
            frameProperties: nextFrameProperties(),
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        rememberLastFrame(pixelBuffer, presentationTimeStamp: timestamp, duration: .invalid)
    }

    public func encode(
        cgImage: CGImage,
        timestamp: CMTime,
        context: CIContext,
        targetSize: CGSize? = nil,
        pool: CVPixelBufferPool? = nil
    ) {
        guard let pixelBuffer = cgImage.toPixelBuffer(
            context: context,
            targetSize: targetSize,
            pool: pool
        ) else {
            return
        }

        encode(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }
}

private extension H264Encoder {
    func nextFrameProperties() -> CFDictionary? {
        guard pendingForceKeyFrame else { return nil }
        pendingForceKeyFrame = false
        return [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
    }

    func extractSPSAndPPS(from sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        var parameterSetCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: nil
        )
        guard parameterSetCount == 2 else { return }

        var spsSize: Int = 0
        var sps: UnsafePointer<UInt8>?

        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: &sps,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        var ppsSize: Int = 0
        var pps: UnsafePointer<UInt8>?

        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 1,
            parameterSetPointerOut: &pps,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        guard let sps = sps,
              let pps = pps else { return }

        for (ptr, size) in [(sps, spsSize), (pps, ppsSize)] {
            var data = Data(capacity: 4 + size)
            data.append(H264Encoder.naluStartCode)
            data.append(ptr, count: size)
            naluHandling?(data)
        }
    }

    // build a SEI NAL unit (user_data_unregistered) carrying the presentation timestamp
    // in microseconds. the UUID prefix lets decoders identify and extract the timecode.
    static func createTimingSEI(pts: CMTime) -> Data {
        let microseconds = UInt64(CMTimeGetSeconds(pts) * 1_000_000)

        // sei_payload: 16-byte UUID + 8-byte big-endian timestamp
        var payload = Data(timingUUID)
        var bigEndianTimestamp = microseconds.bigEndian
        payload.append(Data(bytes: &bigEndianTimestamp, count: 8))

        // sei_message: payloadType(5) + payloadSize(24) + payload
        // then rbsp_trailing_bits
        var rbsp = Data()
        rbsp.append(5)                        // payloadType = user_data_unregistered
        rbsp.append(UInt8(payload.count))     // payloadSize = 24
        rbsp.append(payload)
        rbsp.append(0x80)                     // rbsp_trailing_bits

        let ebsp = addEmulationPrevention(rbsp)

        var nalu = Data([0x06])               // nal_unit_type = 6 (SEI), nal_ref_idc = 0
        nalu.append(ebsp)

        return naluStartCode + nalu
    }

    // insert 0x03 emulation prevention bytes where the RBSP contains
    // sequences that could be mistaken for start codes (00 00 00, 00 00 01, 00 00 02, 00 00 03)
    static func addEmulationPrevention(_ data: Data) -> Data {
        var result = Data()
        var zeroCount = 0
        for byte in data {
            if zeroCount >= 2 && byte <= 0x03 {
                result.append(0x03)
                zeroCount = 0
            }
            result.append(byte)
            zeroCount = (byte == 0x00) ? zeroCount + 1 : 0
        }
        return result
    }
}
