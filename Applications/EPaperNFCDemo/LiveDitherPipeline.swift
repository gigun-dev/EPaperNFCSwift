//
//  LiveDitherPipeline.swift
//  EPaperNFCDemo
//

import CoreGraphics
import CoreImage
import EPaperNFCSwift
import Foundation
import OSLog

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "LiveDitherPipeline"
)

// Quality vs frame-rate tradeoff for the live camera preview. Captured
// frames (sent to the Composer) are always full resolution regardless of
// this setting — this only scales the per-frame dither work.
enum LivePreviewQuality: String, CaseIterable, Identifiable {
    case fast       // 1/2 of display resolution
    case balanced   // 3/4 of display resolution
    case quality    // full display resolution

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .fast: 0.5
        case .balanced: 0.75
        case .quality: 1.0
        }
    }

    var label: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .quality: "Quality"
        }
    }

    var systemImage: String {
        switch self {
        case .fast: "hare.fill"
        case .balanced: "speedometer"
        case .quality: "sparkles"
        }
    }
}

@MainActor
@Observable
final class LiveDitherPipeline {
    private(set) var previewImage: CIImage?
    private(set) var lastFrameDuration: TimeInterval?

    var displayType: DisplayType
    var sCurveStrength: Float
    var unsharpRadius: Float
    var unsharpIntensity: Float
    var previewQuality: LivePreviewQuality {
        didSet {
            if oldValue != previewQuality { restartForParamChange() }
        }
    }

    private var renderTask: Task<Void, Never>?
    private var pending: CIImage?
    private var lastSource: CIImage?

    init(
        displayType: DisplayType,
        sCurveStrength: Float,
        unsharpRadius: Float,
        unsharpIntensity: Float,
        previewQuality: LivePreviewQuality = .balanced
    ) {
        self.displayType = displayType
        self.sCurveStrength = sCurveStrength
        self.unsharpRadius = unsharpRadius
        self.unsharpIntensity = unsharpIntensity
        self.previewQuality = previewQuality
    }

    // Feed a camera frame. Drops the frame if a previous one is still being
    // dithered — only the most recent pending frame is kept so we always
    // render with the freshest data.
    func ingest(_ source: CIImage) {
        lastSource = source
        if renderTask != nil {
            pending = source
            return
        }
        startRender(source)
    }

    private func startRender(_ source: CIImage) {
        renderTask = Task { await self.process(source) }
    }

    // Called when a parameter that affects dither output changes mid-flight.
    // Cancel the in-progress render so the next frame uses the new value
    // immediately, and re-kick using the latest source we have.
    private func restartForParamChange() {
        renderTask?.cancel()
        renderTask = nil
        if let next = pending ?? lastSource {
            pending = nil
            startRender(next)
        }
    }

    private func process(_ source: CIImage) async {
        let started = ProcessInfo.processInfo.systemUptime

        let cropped = centerCropToDisplayAspect(source)
        let scale = previewQuality.scale
        let previewSize = CGSize(
            width: max(1, CGFloat(displayType.width) * scale),
            height: max(1, CGFloat(displayType.height) * scale)
        )
        let scaled = cropped.scaled(
            contentMode: .scaleToFill,
            size: previewSize
        )

        let s = sCurveStrength
        let r = unsharpRadius
        let i = unsharpIntensity
        let palette = displayType.colorPalette

        let ditheredData = await scaled.atkinsonDithered(
            for: palette,
            sCurveStrength: s,
            unsharpRadius: r,
            unsharpIntensity: i
        )

        if Task.isCancelled {
            renderTask = nil
            if let next = pending { pending = nil; startRender(next) }
            return
        }

        let preview = await Self.renderPaletteIndices(
            ditheredData,
            width: Int(previewSize.width),
            height: Int(previewSize.height),
            palette: palette
        )

        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if !Task.isCancelled {
            previewImage = preview
            lastFrameDuration = elapsed
        }

        renderTask = nil
        if let next = pending {
            pending = nil
            startRender(next)
        }
    }

    func croppedToDisplayAspect(_ image: CIImage) -> CIImage {
        centerCropToDisplayAspect(image)
    }

    private func centerCropToDisplayAspect(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let displayAspect = CGFloat(displayType.width) / CGFloat(displayType.height)
        let imageAspect = extent.width / extent.height

        let crop: CGRect
        if imageAspect > displayAspect {
            // Image is wider — crop sides.
            let targetWidth = extent.height * displayAspect
            let dx = (extent.width - targetWidth) / 2
            crop = CGRect(x: extent.origin.x + dx, y: extent.origin.y, width: targetWidth, height: extent.height)
        } else {
            // Image is taller — crop top/bottom.
            let targetHeight = extent.width / displayAspect
            let dy = (extent.height - targetHeight) / 2
            crop = CGRect(x: extent.origin.x, y: extent.origin.y + dy, width: extent.width, height: targetHeight)
        }
        return image.cropped(to: crop)
    }

    @concurrent
    private static func renderPaletteIndices(
        _ data: Data,
        width: Int,
        height: Int,
        palette: DisplayType.ColorPalette
    ) async -> CIImage? {
        let colors = palette.colors
        let pixelCount = width * height
        guard data.count >= pixelCount else { return nil }

        var rgba = [UInt8](repeating: 255, count: pixelCount * 4)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<pixelCount {
                let idx = Int(src[i])
                guard idx < colors.count else { continue }
                let color = colors[idx]
                let base = i * 4
                rgba[base] = color.r
                rgba[base + 1] = color.g
                rgba[base + 2] = color.b
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(
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
              )
        else { return nil }
        return CIImage(cgImage: cg)
    }
}
