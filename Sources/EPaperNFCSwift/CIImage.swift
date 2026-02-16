//
//  CIImage.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/20/26.
//

import CoreImage

extension CIImage {
    // Render this image with Atkinson dithering.
    // Consulted with claude-opus-4-6.
    @concurrent
    public func atkinsonDithered(for colorPalette: DisplayType.ColorPalette) async -> Data {
        let extent = self.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        let pixelCount = width * height

        // Render CIImage to RGBA8 pixel buffer.
        let context = CIContext()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: pixelCount * 4)
        context.render(
            self,
            toBitmap: &pixels,
            rowBytes: width * 4,
            bounds: extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )

        // Precompute palette colors as floats.
        let colors = colorPalette.colors
        let paletteCount = colors.count
        let paletteR = colors.map { Float($0.r) / 255.0 }
        let paletteG = colors.map { Float($0.g) / 255.0 }
        let paletteB = colors.map { Float($0.b) / 255.0 }

        // Use separate flat float arrays for R, G, B channels for better cache behavior.
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

        // Atkinson dithering.
        // Distributes 1/8 of the error to each of 6 neighbors (total 6/8).
        //
        //          *    +1    +2
        //    -1   +0    +1
        //         +0
        //
        bufR.withUnsafeMutableBufferPointer { rBuf in
            bufG.withUnsafeMutableBufferPointer { gBuf in
                bufB.withUnsafeMutableBufferPointer { bBuf in
                    result.withUnsafeMutableBufferPointer { resBuf in
                        let rPtr = rBuf.baseAddress!
                        let gPtr = gBuf.baseAddress!
                        let bPtr = bBuf.baseAddress!
                        let resPtr = resBuf.baseAddress!

                        for y in 0..<height {
                            let rowBase = y &* width
                            for x in 0..<width {
                                let index = rowBase &+ x

                                let cr = rPtr[index]
                                let cg = gPtr[index]
                                let cb = bPtr[index]

                                // Find closest palette color.
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

                                // Compute quantization error * 1/8.
                                let er = (cr - paletteR[bestIndex]) * 0.125
                                let eg = (cg - paletteG[bestIndex]) * 0.125
                                let eb = (cb - paletteB[bestIndex]) * 0.125

                                // Diffuse error to 6 neighbors with inlined bounds checks.
                                // (x+1, y)
                                if x &+ 1 < width {
                                    let ni = index &+ 1
                                    rPtr[ni] += er
                                    gPtr[ni] += eg
                                    bPtr[ni] += eb
                                }
                                // (x+2, y)
                                if x &+ 2 < width {
                                    let ni = index &+ 2
                                    rPtr[ni] += er
                                    gPtr[ni] += eg
                                    bPtr[ni] += eb
                                }
                                if y &+ 1 < height {
                                    let nextRow = rowBase &+ width
                                    // (x-1, y+1)
                                    if x > 0 {
                                        let ni = nextRow &+ x &- 1
                                        rPtr[ni] += er
                                        gPtr[ni] += eg
                                        bPtr[ni] += eb
                                    }
                                    // (x, y+1)
                                    let ni0 = nextRow &+ x
                                    rPtr[ni0] += er
                                    gPtr[ni0] += eg
                                    bPtr[ni0] += eb
                                    // (x+1, y+1)
                                    if x &+ 1 < width {
                                        let ni = nextRow &+ x &+ 1
                                        rPtr[ni] += er
                                        gPtr[ni] += eg
                                        bPtr[ni] += eb
                                    }
                                }
                                // (x, y+2)
                                if y &+ 2 < height {
                                    let ni = rowBase &+ width &* 2 &+ x
                                    rPtr[ni] += er
                                    gPtr[ni] += eg
                                    bPtr[ni] += eb
                                }
                            }
                        }
                    }
                }
            }
        }

        return Data(result)
    }

    public enum ContentMode: Sendable {
        case scaleToFit(backgroundColor: CIColor)
        case scaleToFill
    }

    // Scale this image to fit or fill the given display type's dimensions.
    // Consulted with claude-opus-4-6.
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

        let scaledWidth = sourceExtent.width * scale
        let scaledHeight = sourceExtent.height * scale

        let offsetX = (size.width - scaledWidth) / 2.0
        let offsetY = (size.height - scaledHeight) / 2.0
        let targetRect = CGRect(origin: .zero, size: size)

        let scaledImage = self
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offsetX - sourceExtent.origin.x * scale, y: offsetY - sourceExtent.origin.y * scale))
            .cropped(to: targetRect)

        switch contentMode {
        case .scaleToFit(backgroundColor: let color):
            let backgroundImage = CIImage(color: color).cropped(to: targetRect)
            return scaledImage.composited(over: backgroundImage)

        case .scaleToFill:
            return scaledImage
        }
    }
}

extension Image {
    // Consulted with claude-opus-4-6.
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
