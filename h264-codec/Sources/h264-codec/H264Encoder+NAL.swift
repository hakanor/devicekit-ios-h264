import CoreMedia
import Foundation

// NAL assembly helpers: SPS/PPS extraction and the timing SEI carrying the
// capture timestamp (split out of H264Encoder.swift for swiftlint file_length).
extension H264Encoder {
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
