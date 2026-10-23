import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

struct BeautySettings: Equatable {
    var smoothing: Double = 0.6   // 0...1 skin softening
    var brightness: Double = 0.3  // 0...1
    var warmth: Double = 0.3      // 0...1
    var enabled = true
}

/// Shared by live preview and photo capture; reusable for video frames later.
final class BeautyFilter {
    static let context = CIContext()

    private struct Face {
        var box: CGRect            // normalized, bottom-left origin
        var features: [[CGPoint]]  // eyes, brows, lips as normalized image points
    }

    private let faceRequest = VNDetectFaceLandmarksRequest()
    private var cachedFaces: [Face] = []
    private var cachedMask: CIImage?
    private var cachedMaskExtent = CGRect.zero
    private var frameCounter = 0
    private let lock = NSLock()

    /// Image must already be upright (orientation applied).
    func apply(_ input: CIImage, settings: BeautySettings, detectEvery: Int = 3) -> CIImage {
        guard settings.enabled else { return input }
        let extent = input.extent
        let faces = detectFaces(in: input, every: detectEvery)

        var output = input
        if settings.smoothing > 0, !faces.isEmpty {
            output = smooth(input, faces: faces, extent: extent, amount: settings.smoothing)
        }

        let colors = CIFilter.colorControls()
        colors.inputImage = output
        colors.brightness = Float(settings.brightness * 0.12)
        colors.saturation = 1.0 + Float(settings.smoothing * 0.05)
        colors.contrast = 1.0
        output = colors.outputImage ?? output

        if settings.warmth > 0 {
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6500 - CGFloat(settings.warmth) * 900, y: 0)
            output = temp.outputImage ?? output
        }
        return output.cropped(to: extent)
    }

    private func detectFaces(in image: CIImage, every n: Int) -> [Face] {
        lock.lock(); defer { lock.unlock() }
        frameCounter += 1
        if n > 1 && frameCounter % n != 1 { return cachedFaces }
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([faceRequest])
        cachedFaces = (faceRequest.results ?? []).map { obs in
            let box = obs.boundingBox
            let regions = [obs.landmarks?.leftEye, obs.landmarks?.rightEye,
                           obs.landmarks?.leftEyebrow, obs.landmarks?.rightEyebrow,
                           obs.landmarks?.outerLips]
            let features = regions.compactMap { $0 }.map { region in
                region.normalizedPoints.map {
                    CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height)
                }
            }
            return Face(box: box, features: features)
        }
        cachedMask = nil
        return cachedFaces
    }

    private func smooth(_ image: CIImage, faces: [Face], extent: CGRect, amount: Double) -> CIImage {
        let denoise = CIFilter.noiseReduction()
        denoise.inputImage = image
        denoise.noiseLevel = Float(0.02 + 0.04 * amount)
        denoise.sharpness = 0.2
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = denoise.outputImage?.clampedToExtent()
        blur.radius = Float(2 + 6 * amount) * Float(extent.width / 1080)
        let soft = (blur.outputImage ?? image).cropped(to: extent)

        let k = CGFloat(amount * 0.85)
        let mask = faceMask(faces: faces, extent: extent).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0)
        ])
        let blend = CIFilter.blendWithMask()
        blend.inputImage = soft
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage ?? image
    }

    private func faceMask(faces: [Face], extent: CGRect) -> CIImage {
        if let cachedMask, cachedMaskExtent == extent { return cachedMask }
        var mask = CIImage(color: .black).cropped(to: extent)
        for face in faces {
            let w = face.box.width * extent.width
            let h = face.box.height * extent.height
            let cx = extent.minX + face.box.midX * extent.width
            let cy = extent.minY + face.box.midY * extent.height
            let gradient = CIFilter.radialGradient()
            gradient.center = .zero
            gradient.radius0 = 0.75
            gradient.radius1 = 1.0
            gradient.color0 = .white
            gradient.color1 = .black
            let transform = CGAffineTransform(translationX: cx, y: cy + h * 0.05)
                .scaledBy(x: w * 0.65, y: h * 0.75)
            let ellipse = gradient.outputImage!.transformed(by: transform).cropped(to: extent)
            mask = ellipse.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }
        // Keep eyes, brows and lips sharp by multiplying with the inverse of a feature mask.
        let keep = featureMask(faces: faces, extent: extent).applyingFilter("CIColorInvert")
        mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: keep])
            .cropped(to: extent)
        cachedMask = mask
        cachedMaskExtent = extent
        return mask
    }

    /// White where features are, drawn at low resolution, then upscaled and feathered.
    private func featureMask(faces: [Face], extent: CGRect) -> CIImage {
        let scale = 512 / max(extent.width, extent.height)
        let w = max(Int(extent.width * scale), 1), h = max(Int(extent.height * scale), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: .black).cropped(to: extent)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineWidth(5)
        ctx.setLineJoin(.round)
        for face in faces {
            for points in face.features where points.count > 2 {
                ctx.beginPath()
                ctx.addLines(between: points.map { CGPoint(x: $0.x * CGFloat(w), y: $0.y * CGFloat(h)) })
                ctx.closePath()
                ctx.drawPath(using: .fillStroke)
            }
        }
        guard let cg = ctx.makeImage() else { return CIImage(color: .black).cropped(to: extent) }
        let up = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let feather = CIFilter.gaussianBlur()
        feather.inputImage = up.clampedToExtent()
        feather.radius = Float(extent.width * 0.006)
        return (feather.outputImage ?? up).cropped(to: extent)
    }
}
