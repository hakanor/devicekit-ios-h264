import CoreMedia
import CoreVideo
import VideoToolbox

// Keyframe control. ReplayKit only delivers samples when the screen changes, so
// "force a keyframe on the next frame" never fires on a static screen — a client
// connecting to an idle device would wait for the next screen change before it
// ever saw SPS/PPS+IDR. We keep the last frame and re-encode it on demand.
// lastFrameLock guards the last-frame fields: written from ReplayKit's sample
// thread, read from the TCP connection queue.
extension H264Encoder {
    public func forceNextKeyFrame() {
        pendingForceKeyFrame = true
    }

    /// Re-encodes the most recent frame as a keyframe right now. Falls back to
    /// forcing the next real frame when nothing has been encoded yet.
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

    func rememberLastFrame(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime, duration: CMTime) {
        lastFrameLock.lock()
        lastPixelBuffer = pixelBuffer
        lastPresentationTimeStamp = presentationTimeStamp
        lastDuration = duration
        lastFrameLock.unlock()
    }

    func forgetLastFrame() {
        lastFrameLock.lock()
        lastPixelBuffer = nil
        lastPresentationTimeStamp = .invalid
        lastFrameLock.unlock()
    }

    func nextFrameProperties() -> CFDictionary? {
        guard pendingForceKeyFrame else { return nil }
        pendingForceKeyFrame = false
        return [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
    }
}
