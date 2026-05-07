//
//  MetalCIPreviewView.swift
//  EPaperNFCDemo
//

import CoreImage
import MetalKit
import SwiftUI

struct MetalCIPreviewView: UIViewRepresentable {
    let image: CIImage?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.image = image
        uiView.setNeedsDisplay()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private let ciContext: CIContext?
        var image: CIImage?

        override init() {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            if let device {
                self.ciContext = CIContext(mtlDevice: device, options: [
                    .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
                ])
            } else {
                self.ciContext = nil
            }
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // SwiftUI frame change → MTKView drawable resize. Without this,
            // MTKView keeps its previously-drawn texture and stretches it
            // into the new bounds, which squashes the image during layout
            // animations (e.g. opening/closing the Tune panel).
            Task { @MainActor in view.setNeedsDisplay() }
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                drawOnMain(in: view)
            }
        }

        private func drawOnMain(in view: MTKView) {
            guard let image,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let ciContext
            else { return }

            let drawableSize = view.drawableSize
            let extent = image.extent
            guard extent.width > 0, extent.height > 0,
                  drawableSize.width > 0, drawableSize.height > 0
            else { return }

            // Aspect-fit. Use nearest-neighbor sampling so the dithered pixels
            // stay crisp when scaled up.
            let scale = min(drawableSize.width / extent.width, drawableSize.height / extent.height)
            let scaledWidth = extent.width * scale
            let scaledHeight = extent.height * scale
            let dx = (drawableSize.width - scaledWidth) / 2
            let dy = (drawableSize.height - scaledHeight) / 2

            let scaled = image
                .samplingNearest()
                .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: dx, y: dy))

            let destination = CIRenderDestination(
                width: Int(drawableSize.width),
                height: Int(drawableSize.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture }
            )
            destination.isFlipped = true

            do {
                _ = try ciContext.startTask(toRender: scaled, to: destination)
            } catch {
                // Drop frame on render error.
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
