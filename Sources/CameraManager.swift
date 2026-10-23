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

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
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

    func stop() { sessionQueue.async { self.session.stopRunning() } }

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
            self.lastSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.lastSaved = false }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let current = settingsLock.withLock { liveSettings }
        let result = liveFilter.apply(CIImage(cvPixelBuffer: buffer), settings: current)
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
