//
//  CIImage.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/20/26.
//

import CoreImage

// Selectable dithering strategy. There is currently a single strategy because
// the e-paper firmware on this device does not tolerate dithered images
// produced without preprocessing — image content with finely scattered
// yellow/red pixels triggers an MCU stall mid-refresh that drops the NFC
// connection. The `standard` strategy applies a mild S-curve and unsharp
// mask before sRGB error diffusion, both of which empirically keep refresh
// reliable. The enum is kept (rather than collapsing to a free function) so
// the diagnostics log can record which strategy produced an entry, and to
// leave room for adding alternatives later without an API break.
public enum DitheringStrategy: String, Sendable, CaseIterable, Hashable, Identifiable {
    case standard

    public var id: Self { self }
}

extension CIImage {
    public enum ContentMode: Sendable {
        case scaleToFit(backgroundColor: CIColor)
        case scaleToFill
    }

    // Scale this image to fit or fill the given display dimensions using a
    // Lanczos resampler.
    public func scaled(contentMode: ContentMode, size: CGSize) -> CIImage {
        let sourceExtent = self.extent

        let scaleX = size.width / sourceExtent.width
        let scaleY = size.height / sourceExtent.height
        let scale: CGFloat
        switch contentMode {
        case .scaleToFit:
            scale = min(scaleX, scaleY)
        case .scaleToFill:
            scale = max(scaleX, scaleY)
        }

        // Origin-shift first so Lanczos sees an image whose extent starts at
        // (0, 0); CILanczosScaleTransform's coordinate handling is well-defined
        // only in that case.
        let zeroOriginedSource = self.transformed(
            by: CGAffineTransform(translationX: -sourceExtent.origin.x, y: -sourceExtent.origin.y)
        )
        let lanczos = zeroOriginedSource.applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0
            ]
        )

        let scaledWidth = sourceExtent.width * scale
        let scaledHeight = sourceExtent.height * scale
        let offsetX = (size.width - scaledWidth) / 2.0
        let offsetY = (size.height - scaledHeight) / 2.0
        let targetRect = CGRect(origin: .zero, size: size)

        let scaledImage = lanczos
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .cropped(to: targetRect)

        switch contentMode {
        case .scaleToFit(backgroundColor: let color):
            let backgroundImage = CIImage(color: color).cropped(to: targetRect)
            return scaledImage.composited(over: backgroundImage)

        case .scaleToFill:
            return scaledImage
        }
    }

    // Render this image with serpentine Atkinson dithering into a palette
    // index buffer. The `sCurveStrength`, `unsharpRadius` and
    // `unsharpIntensity` parameters control preprocessing applied before
    // quantization. The dither runs in sRGB-encoded space and selects the
    // nearest palette color by Euclidean distance.
    //
    // The function honours task cancellation: if the surrounding `Task`
    // is cancelled mid-loop the function returns early. The returned `Data`
    // is well-formed (correct byte count, palette indices in range), but the
    // contents past the cancellation point reflect the un-quantized initial
    // state. Callers that need a guarantee of completeness should check
    // `Task.isCancelled` after `await` and discard the result if cancelled.
    @concurrent
    public func atkinsonDithered(
        for colorPalette: DisplayType.ColorPalette,
        strategy: DitheringStrategy = .standard,
        sCurveStrength: Float = 1.0,
        unsharpRadius: Float = 1.0,
        unsharpIntensity: Float = 0.7
    ) async -> Data {
        _ = strategy
        let extent = self.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        let pixelCount = width * height

        // Preprocessing: a mild S-curve to push midtones toward extremes,
        // followed by an unsharp mask to emphasise edges. Empirically these
        // two operations, in this order, produce dithered output that the
        // e-paper firmware can refresh without losing the NFC connection.
        var prepared = self
        if sCurveStrength > 0.001 {
            // The S-curve interpolates between identity (strength 0) and the
            // canonical curve (strength 1); strengths > 1 are more aggressive.
            let dy = CGFloat(0.05 * sCurveStrength)
            prepared = prepared.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.00, y: 0.00),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 - dy),
                "inputPoint2": CIVector(x: 0.50, y: 0.50),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + dy),
                "inputPoint4": CIVector(x: 1.00, y: 1.00)
            ])
        }
        if unsharpIntensity > 0.001 && unsharpRadius > 0.001 {
            prepared = prepared.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: unsharpRadius,
                kCIInputIntensityKey: unsharpIntensity
            ])
            .cropped(to: extent)
        }

        // Render to RGBA8 sRGB.
        let context = CIContext()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: pixelCount * 4)
        context.render(
            prepared,
            toBitmap: &pixels,
            rowBytes: width * 4,
            bounds: extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )

        // Palette in sRGB float space (matches diffusion-space encoding).
        let colors = colorPalette.colors
        let paletteCount = colors.count
        var paletteR = [Float](repeating: 0, count: paletteCount)
        var paletteG = [Float](repeating: 0, count: paletteCount)
        var paletteB = [Float](repeating: 0, count: paletteCount)
        for i in 0..<paletteCount {
            paletteR[i] = Float(colors[i].r) / 255.0
            paletteG[i] = Float(colors[i].g) / 255.0
            paletteB[i] = Float(colors[i].b) / 255.0
        }

        // Working error-diffusion buffers (sRGB float).
        var bufR = [Float](repeating: 0, count: pixelCount)
        var bufG = [Float](repeating: 0, count: pixelCount)
        var bufB = [Float](repeating: 0, count: pixelCount)
        pixels.withUnsafeBufferPointer { src in
            for i in 0..<pixelCount {
                let base = i &* 4
                bufR[i] = Float(src[base]) / 255.0
                bufG[i] = Float(src[base &+ 1]) / 255.0
                bufB[i] = Float(src[base &+ 2]) / 255.0
            }
        }

        var result = [UInt8](repeating: 0, count: pixelCount)

        // Serpentine Atkinson: 6 neighbours at 1/8 each, scan direction
        // alternates per row. Cancellation is checked every 16 rows so that a
        // caller (e.g. an interactive slider) can abandon a stale dither
        // quickly.
        bufR.withUnsafeMutableBufferPointer { rBuf in
            bufG.withUnsafeMutableBufferPointer { gBuf in
                bufB.withUnsafeMutableBufferPointer { bBuf in
                    result.withUnsafeMutableBufferPointer { resBuf in
                        let rPtr = rBuf.baseAddress!
                        let gPtr = gBuf.baseAddress!
                        let bPtr = bBuf.baseAddress!
                        let resPtr = resBuf.baseAddress!

                        for y in 0..<height {
                            if y & 15 == 0 && Task.isCancelled { return }
                            let rowBase = y &* width
                            let reverse = (y & 1) == 1
                            let dir: Int = reverse ? -1 : 1
                            let xStart = reverse ? width &- 1 : 0
                            var x = xStart
                            for _ in 0..<width {
                                let index = rowBase &+ x

                                let cr = max(0, min(1, rPtr[index]))
                                let cg = max(0, min(1, gPtr[index]))
                                let cb = max(0, min(1, bPtr[index]))

                                // Nearest palette color (Euclidean in sRGB).
                                var bestIndex = 0
                                var bestDistance = Float.greatestFiniteMagnitude
                                for i in 0..<paletteCount {
                                    let dr = cr - paletteR[i]
                                    let dg = cg - paletteG[i]
                                    let db = cb - paletteB[i]
                                    let distance = dr * dr + dg * dg + db * db
                                    if distance < bestDistance {
                                        bestDistance = distance
                                        bestIndex = i
                                    }
                                }
                                resPtr[index] = UInt8(bestIndex)

                                // Quantization error * 1/8 to each of 6
                                // Atkinson neighbours.
                                let er = (rPtr[index] - paletteR[bestIndex]) * 0.125
                                let eg = (gPtr[index] - paletteG[bestIndex]) * 0.125
                                let eb = (bPtr[index] - paletteB[bestIndex]) * 0.125

                                let x1 = x &+ dir
                                if x1 >= 0 && x1 < width {
                                    let ni = rowBase &+ x1
                                    rPtr[ni] += er; gPtr[ni] += eg; bPtr[ni] += eb
                                }
                                let x2 = x &+ (dir &* 2)
                                if x2 >= 0 && x2 < width {
                                    let ni = rowBase &+ x2
                                    rPtr[ni] += er; gPtr[ni] += eg; bPtr[ni] += eb
                                }
                                if y &+ 1 < height {
                                    let nextRow = rowBase &+ width
                                    let xm = x &- dir
                                    if xm >= 0 && xm < width {
                                        let ni = nextRow &+ xm
                                        rPtr[ni] += er; gPtr[ni] += eg; bPtr[ni] += eb
                                    }
                                    let ni0 = nextRow &+ x
                                    rPtr[ni0] += er; gPtr[ni0] += eg; bPtr[ni0] += eb
                                    if x1 >= 0 && x1 < width {
                                        let ni = nextRow &+ x1
                                        rPtr[ni] += er; gPtr[ni] += eg; bPtr[ni] += eb
                                    }
                                }
                                if y &+ 2 < height {
                                    let ni = rowBase &+ width &* 2 &+ x
                                    rPtr[ni] += er; gPtr[ni] += eg; bPtr[ni] += eb
                                }

                                x = x &+ dir
                            }
                        }
                    }
                }
            }
        }

        return Data(result)
    }
}

extension Image {
    @concurrent
    public func renderCIImage() async -> CIImage {
        let width = displayType.width
        let height = displayType.height
        let colors = displayType.colorPalette.colors

        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let colorIndex = Int(data[i])
            let color = colors[colorIndex]
            let base = i * 4
            rgba[base] = color.r
            rgba[base + 1] = color.g
            rgba[base + 2] = color.b
            rgba[base + 3] = 255
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!

        return CIImage(cgImage: cgImage)
    }
}
