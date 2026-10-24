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

    private static let skinCubeSize = 32
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private let faceRequest = VNDetectFaceLandmarksRequest()
    private var cachedFaces: [Face] = []
    private var cachedSkinCube: Data?
    private var cachedMask: CIImage?
    private var cachedMaskExtent = CGRect.zero
    private var frameCounter = 0
    private let lock = NSLock()

    /// Image must already be upright (orientation applied).
    func apply(_ input: CIImage, settings: BeautySettings, detectEvery: Int = 3) -> CIImage {
        guard settings.enabled else { return input }
        let extent = input.extent
        let (faces, skinCube) = detectFaces(in: input, every: detectEvery)

        var output = input
        if settings.smoothing > 0, !faces.isEmpty {
            output = smooth(input, faces: faces, skinCube: skinCube, extent: extent, amount: settings.smoothing)
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

    private func detectFaces(in image: CIImage, every n: Int) -> (faces: [Face], skinCube: Data?) {
        lock.lock(); defer { lock.unlock() }
        frameCounter += 1
        if n > 1 && frameCounter % n != 1 { return (cachedFaces, cachedSkinCube) }
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
        let tones = cachedFaces.compactMap { skinTone(in: image, face: $0) }
        cachedSkinCube = Self.skinCube(tones: tones)
        cachedMask = nil
        return (cachedFaces, cachedSkinCube)
    }

    /// Average cheek/nose color as (Y, Cb, Cr) in sRGB, so the skin mask adapts to each person's tone and lighting.
    private func skinTone(in image: CIImage, face: Face) -> SIMD3<Float>? {
        let e = image.extent, b = face.box
        let cheek = CGRect(x: e.minX + (b.minX + b.width * 0.25) * e.width,
                           y: e.minY + (b.minY + b.height * 0.3) * e.height,
                           width: b.width * 0.5 * e.width,
                           height: b.height * 0.25 * e.height).intersection(e)
        guard !cheek.isNull, !cheek.isEmpty else { return nil }
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: cheek)])
        var px = [UInt8](repeating: 0, count: 4)
        Self.context.render(avg, toBitmap: &px, rowBytes: 4, bounds: avg.extent, format: .RGBA8, colorSpace: Self.sRGB)
        return Self.ycbcr(Float(px[0]) / 255, Float(px[1]) / 255, Float(px[2]) / 255)
    }

    private static func ycbcr(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        SIMD3(0.299 * r + 0.587 * g + 0.114 * b,
              0.5 - 0.168736 * r - 0.331264 * g + 0.5 * b,
              0.5 + 0.5 * r - 0.418688 * g - 0.081312 * b)
    }

    private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// sRGB lookup cube: white where a color is close in chroma to any detected skin tone and not much darker.
    private static func skinCube(tones: [SIMD3<Float>]) -> Data? {
        guard !tones.isEmpty else { return nil }
        let n = skinCubeSize
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let c = ycbcr(Float(r) / Float(n - 1), Float(g) / Float(n - 1), Float(b) / Float(n - 1))
                    var p: Float = 0
                    for t in tones {
                        let d = hypotf(c.y - t.y, c.z - t.z)
                        let chroma = 1 - smoothstep(0.035, 0.085, d)
                        let luma = smoothstep(t.x * 0.3, t.x * 0.55, c.x)
                        p = max(p, chroma * luma)
                    }
                    // Output is decoded as sRGB, so pre-encode to keep the mask linear.
                    let v = powf(p, 1 / 2.2)
                    cube[i] = v; cube[i + 1] = v; cube[i + 2] = v; cube[i + 3] = 1
                    i += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func ellipseRect(_ face: Face, in extent: CGRect) -> CGRect {
        let w = face.box.width * extent.width
        let h = face.box.height * extent.height
        let cx = extent.minX + face.box.midX * extent.width
        let cy = extent.minY + face.box.midY * extent.height + h * 0.05
        return CGRect(x: cx - w * 0.65, y: cy - h * 0.75, width: w * 1.3, height: h * 1.5)
    }

    private func smooth(_ image: CIImage, faces: [Face], skinCube: Data?, extent: CGRect, amount: Double) -> CIImage {
        let region = faces.reduce(CGRect.null) { $0.union(ellipseRect($1, in: extent)) }.intersection(extent)
        guard !region.isNull, !region.isEmpty else { return image }
        let scale = Double(extent.width / 1080)
        let src = image.cropped(to: region).clampedToExtent()
        func blur(_ sigma: Double) -> CIImage { src.applyingGaussianBlur(sigma: sigma * scale).cropped(to: region) }
        let fine = blur(1.2)
        let mid = blur(3)
        let low = blur(4 + 8 * amount)

        // Structural edges (nose, jaw, eyelids) survive the mid blur; pores and blemishes don't.
        // Where mid and low differ, fall back to the fine blur so contours stay crisp.
        let gain: CGFloat = 16, threshold: CGFloat = 0.012
        let flat = mid.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: low])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -gain / 3, y: -gain / 3, z: -gain / 3, w: 0),
                "inputGVector": CIVector(x: -gain / 3, y: -gain / 3, z: -gain / 3, w: 0),
                "inputBVector": CIVector(x: -gain / 3, y: -gain / 3, z: -gain / 3, w: 0),
                "inputBiasVector": CIVector(x: 1 + gain * threshold, y: 1 + gain * threshold, z: 1 + gain * threshold, w: 0)
            ])
            .applyingFilter("CIColorClamp")
        let soft = low.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: fine,
            kCIInputMaskImageKey: flat
        ])

        var mask = faceMask(faces: faces, extent: extent).cropped(to: region)
        if let skinCube {
            let skin = src.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": Self.skinCubeSize,
                "inputCubeData": skinCube,
                "inputColorSpace": Self.sRGB
            ]).applyingGaussianBlur(sigma: 1.5 * scale).cropped(to: region)
            mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: skin])
        }
        let k = CGFloat(amount * 0.85)
        mask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0)
        ])
        return soft.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image.cropped(to: region),
            kCIInputMaskImageKey: mask
        ]).cropped(to: region).composited(over: image)
    }

    private func faceMask(faces: [Face], extent: CGRect) -> CIImage {
        if let cachedMask, cachedMaskExtent == extent { return cachedMask }
        var mask = CIImage(color: .black).cropped(to: extent)
        for face in faces {
            let r = ellipseRect(face, in: extent)
            let gradient = CIFilter.radialGradient()
            gradient.center = .zero
            gradient.radius0 = 0.75
            gradient.radius1 = 1.0
            gradient.color0 = .white
            gradient.color1 = .black
            let transform = CGAffineTransform(translationX: r.midX, y: r.midY)
                .scaledBy(x: r.width / 2, y: r.height / 2)
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
