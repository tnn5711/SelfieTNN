import AVFoundation
import CoreImage

/// Writes beautified frames plus microphone audio to a .mov file.
/// Not thread-safe: call every method from the same serial queue (the camera frame queue).
final class VideoRecorder {
    private(set) var isActive = false

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

    func appendVideo(_ image: CIImage, time: CMTime, context: CIContext) {
        guard isActive else { return }
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
        guard isActive, sessionStarted, let input = audioInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
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
