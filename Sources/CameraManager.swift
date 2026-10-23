import AVFoundation
import CoreImage
import Photos
import UIKit

final class CameraManager: NSObject, ObservableObject {
    @Published var settings = BeautySettings() { didSet { settingsLock.withLock { liveSettings = settings } } }
    @Published var previewImage: CGImage?
    @Published var authorized = false
    @Published var lastSaved = false
    @Published var lastPhotoURL: URL?
    @Published var errorMessage: String?
    @Published var recordingStartedAt: Date?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var audioInput: AVCaptureDeviceInput?
    private var recorder: VideoRecorder?   // touched only on frameQueue
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let frameQueue = DispatchQueue(label: "camera.frames")
    private let liveFilter = BeautyFilter()
    private let photoFilter = BeautyFilter()
    private let settingsLock = NSLock()
    private var liveSettings = BeautySettings()
    private var position: AVCaptureDevice.Position = .front
    private var input: AVCaptureDeviceInput?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { self.authorized = ok }
                if ok { self.configureAndRun() }
            }
        default: DispatchQueue.main.async { self.authorized = false }
        }
    }

    func stop() {
        stopRecording()
        sessionQueue.async { self.session.stopRunning() }
    }

    private func configureAndRun() {
        DispatchQueue.main.async { self.authorized = true }
        sessionQueue.async {
            if self.session.inputs.isEmpty {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                self.setInput(position: self.position)
                self.videoOutput.setSampleBufferDelegate(self, queue: self.frameQueue)
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
                if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
                self.session.commitConfiguration()
                self.updateConnections()
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func setInput(position: AVCaptureDevice.Position) {
        if let input { session.removeInput(input) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else { return }
        session.addInput(newInput)
        input = newInput
    }

    private func updateConnections() {
        for output in [videoOutput as AVCaptureOutput, photoOutput] {
            guard let c = output.connection(with: .video) else { continue }
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = position == .front
            }
        }
    }

    func flip() {
        sessionQueue.async {
            self.position = self.position == .front ? .back : .front
            self.session.beginConfiguration()
            self.setInput(position: self.position)
            self.session.commitConfiguration()
            self.updateConnections()
        }
    }

    func capture() {
        let s = photoOutput.availablePhotoCodecTypes.contains(.hevc)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: s, delegate: self)
    }

    private func save(_ image: UIImage) {
        let url = PhotoStore.add(image)
        DispatchQueue.main.async {
            guard let url else { self.errorMessage = "Could not save photo."; return }
            self.lastPhotoURL = url
            self.flashSaved()
        }
    }

    private func flashSaved() {
        lastSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.lastSaved = false }
    }

    // MARK: Video

    func startRecording() {
        guard recordingStartedAt == nil else { return }
        recordingStartedAt = Date()
        requestMicrophone { micAllowed in
            self.sessionQueue.async {
                if micAllowed { self.addAudioIfNeeded() }
                let hasAudio = micAllowed && self.audioInput != nil
                let settings = hasAudio ? self.audioWriterSettings() : nil
                self.frameQueue.async {
                    let r = VideoRecorder()
                    r.start(audioSettings: settings)
                    self.recorder = r
                }
            }
        }
    }

    func stopRecording() {
        guard recordingStartedAt != nil else { return }
        recordingStartedAt = nil
        frameQueue.async {
            guard let r = self.recorder else { return }
            self.recorder = nil
            r.finish { tempURL in
                let url = tempURL.flatMap { PhotoStore.addVideo(from: $0) }
                DispatchQueue.main.async {
                    guard let url else { self.errorMessage = "Could not save video."; return }
                    self.lastPhotoURL = url
                    self.flashSaved()
                }
            }
        }
    }

    private func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: done)
        default: done(false)
        }
    }

    private func addAudioIfNeeded() {
        guard audioInput == nil,
              let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic) else { return }
        session.beginConfiguration()
        if session.canAddInput(input), session.canAddOutput(audioOutput) {
            session.addInput(input)
            audioOutput.setSampleBufferDelegate(self, queue: frameQueue)
            session.addOutput(audioOutput)
            audioInput = input
        }
        session.commitConfiguration()
    }

    private func audioWriterSettings() -> [String: Any] {
        (audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]) ?? [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 64000
        ]
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var source = CIImage(cvPixelBuffer: buffer)
        // Cap working resolution to keep filtering and encoding real-time.
        let scale = min(1, 1920 / max(source.extent.width, source.extent.height))
        if scale < 1 { source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }

        let current = settingsLock.withLock { liveSettings }
        let result = liveFilter.apply(source, settings: current)
        recorder?.appendVideo(result, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                              context: BeautyFilter.context)
        guard let cg = BeautyFilter.context.createCGImage(result, from: result.extent) else { return }
        DispatchQueue.main.async { self.previewImage = cg }
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), var ci = CIImage(data: data) else { return }
        // Bake in EXIF orientation so Vision and filters see an upright image.
        if let raw = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32,
           let o = CGImagePropertyOrientation(rawValue: raw) {
            ci = ci.oriented(o)
        }
        let current = settingsLock.withLock { liveSettings }
        let out = photoFilter.apply(ci, settings: current, detectEvery: 1)
        guard let cg = BeautyFilter.context.createCGImage(out, from: out.extent) else { return }
        save(UIImage(cgImage: cg))
    }
}
