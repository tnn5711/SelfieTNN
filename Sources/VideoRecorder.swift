import AVFoundation
import CoreImage

/// Writes beautified frames plus microphone audio to a .mov file.
/// Not thread-safe: call every method from the same serial queue (the camera frame queue).
final class VideoRecorder {
    private(set) var isActive = false

    private var isPaused = false
    private var pendingResume = false
    private var offset = CMTime.zero          // total paused time removed from the timeline
    private var lastVideoTime = CMTime.invalid
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioSettings: [String: Any]?
    private var size = CGSize.zero
    private var sessionStarted = false
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rec_\(UUID().uuidString).mov")

    /// Pass nil to record video without audio.
    func start(audioSettings: [String: Any]?) {
        self.audioSettings = audioSettings
        isActive = true
    }

    func pause() { if isActive { isPaused = true } }

    func resume() {
        guard isActive, isPaused else { return }
        isPaused = false
        pendingResume = true
    }

    func appendVideo(_ image: CIImage, time rawTime: CMTime, context: CIContext) {
        guard isActive, !isPaused else { return }
        if pendingResume {
            // Close the gap left by the pause, keeping one frame interval between the clips.
            if lastVideoTime.isValid {
                offset = offset + (rawTime - lastVideoTime) - CMTime(value: 1, timescale: 30)
            }
            pendingResume = false
        }
        lastVideoTime = rawTime
        let time = rawTime - offset

        if writer == nil, !setUpWriter(for: image.extent, startTime: time) { isActive = false; return }
        guard sessionStarted, let input = videoInput, input.isReadyForMoreMediaData,
              let pool = adaptor?.pixelBufferPool else { return }

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        let origin = image.extent.origin
        let normalized = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        context.render(normalized, to: buffer, bounds: CGRect(origin: .zero, size: size),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        adaptor?.append(buffer, withPresentationTime: time)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        // Audio resumes only once the first video frame after a pause has set the new offset.
        guard isActive, !isPaused, !pendingResume, sessionStarted,
              let input = audioInput, input.isReadyForMoreMediaData else { return }
        if offset == .zero {
            input.append(sampleBuffer)
        } else if let shifted = retimed(sampleBuffer, by: offset) {
            input.append(shifted)
        }
    }

    private func retimed(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in 0..<timing.count {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    func finish(completion: @escaping (URL?) -> Void) {
        isActive = false
        guard let writer, sessionStarted, writer.status == .writing else {
            writer?.cancelWriting()
            completion(nil)
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [url] in
            completion(writer.status == .completed ? url : nil)
        }
    }

    private func setUpWriter(for extent: CGRect, startTime: CMTime) -> Bool {
        // H.264 needs even dimensions.
        let w = Int(extent.width) / 2 * 2, h = Int(extent.height) / 2 * 2
        guard w > 0, h > 0, let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        size = CGSize(width: w, height: h)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: w * h * 6]
        ])
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h
        ])
        guard writer.canAdd(video) else { return false }
        writer.add(video)

        if let audioSettings {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) { writer.add(audio); audioInput = audio }
        }

        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: startTime)
        self.writer = writer
        videoInput = video
        self.adaptor = adaptor
        sessionStarted = true
        return true
    }
}
