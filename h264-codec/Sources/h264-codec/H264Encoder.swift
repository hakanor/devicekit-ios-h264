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

    var session: VTCompressionSession?
    var pendingForceKeyFrame = false

    // Last frame handed to the encoder; see H264Encoder+KeyFrame.swift.
    let lastFrameLock = NSLock()
    var lastPixelBuffer: CVPixelBuffer?
    var lastPresentationTimeStamp = CMTime.invalid
    var lastDuration = CMTime.invalid

    static let naluStartCode = Data([UInt8](arrayLiteral: 0x00, 0x00, 0x00, 0x01))

    // uuid for timing SEI (user data unregistered)
    static let timingUUID: [UInt8] = [
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
            // High profile matches devicekit-android's AVCProfileHigh and what
            // webrtc-server now declares in its SDP (profile-level-id=64001f,
            // see backend PR #378) — a Baseline encoder under a High-profile SDP
            // declaration is a real decoder-side mismatch, not just a label.
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
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

    public func invalidateCompressionSession() {
        guard let session = session else {
            return
        }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        forgetLastFrame()
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
