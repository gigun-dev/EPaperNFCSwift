//
//  CameraView.swift
//  EPaperNFCDemo
//

import AVFoundation
import CoreImage
import EPaperNFCSwift
import OSLog
import SwiftUI
import UIKit

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "CameraView"
)

// Live dither camera. Sliders are adjusted post-capture in ComposerView; this
// screen uses the current slider values for the live preview but doesn't let
// the user change them, keeping the shooting experience uncluttered.
struct CameraView: View {
    let displayType: DisplayType
    let sCurveStrength: Float
    let unsharpRadius: Float
    let unsharpIntensity: Float
    var onCapture: (CIImage) -> Void
    // Tap on the bottom-left thumbnail. Parent decides where to go — currently
    // switches to the Photos tab so the user lands inside the gallery rather
    // than just re-opening the last picture.
    var onTapHistoryThumb: () -> Void = {}
    // Long-press on the bottom-left thumbnail re-opens the most recent
    // history entry directly in the Composer.
    var onLongPressHistoryThumb: (HistoryEntry) -> Void = { _ in }

    @AppStorage("livePreviewQuality") private var previewQualityRaw: String = LivePreviewQuality.balanced.rawValue
    @AppStorage("frontCameraWide") private var frontWide: Bool = false

    // Standard-selfie crop factor for the TrueDepth camera. iOS Camera's
    // "1×" front framing is roughly a 1.4× digital crop of the camera's
    // native (wide) FOV.
    private let frontNormalZoom: CGFloat = 1.4

    @Environment(OrientationObserver.self) private var orientation
    @Environment(HistoryStore.self) private var historyStore

    @State private var session = CameraSession()
    @State private var pipeline: LiveDitherPipeline?
    @State private var isCapturing: Bool = false
    @State private var focusIndicator: FocusIndicator?
    @State private var isBoosting: Bool = false

    private struct FocusIndicator: Identifiable {
        let id = UUID()
        let location: CGPoint
    }

    private var previewQuality: LivePreviewQuality {
        LivePreviewQuality(rawValue: previewQualityRaw) ?? .balanced
    }

    private var iconRotation: Angle { orientation.iconRotation }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            // Hosting view for AVCaptureEventInteraction. Must remain in the
            // rendered hierarchy (don't use opacity 0 / hidden — SwiftUI may
            // skip rendering and the interaction will never receive events).
            VolumeShutterAttachment(onShutter: { shutter() })
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .preferredColorScheme(.dark)
        .task {
            if pipeline == nil {
                pipeline = LiveDitherPipeline(
                    displayType: displayType,
                    sCurveStrength: sCurveStrength,
                    unsharpRadius: unsharpRadius,
                    unsharpIntensity: unsharpIntensity,
                    previewQuality: previewQuality
                )
            }
            orientation.subscribe()
            await session.start()
            session.setVideoRotationAngle(orientation.videoRotationAngle)
        }
        .onDisappear {
            session.stop()
            orientation.unsubscribe()
        }
        .onChange(of: session.latestImage) { _, newValue in
            if let newValue, let pipeline {
                pipeline.ingest(newValue)
            }
        }
        .onChange(of: previewQuality) { _, newValue in
            if !isBoosting { pipeline?.previewQuality = newValue }
        }
        .onChange(of: isBoosting) { _, boosting in
            pipeline?.previewQuality = boosting ? .quality : previewQuality
        }
        .onChange(of: orientation.orientation) { _, _ in
            session.setVideoRotationAngle(orientation.videoRotationAngle)
        }
        .onChange(of: session.position) { _, newPosition in
            if newPosition == .front {
                applyFrontFraming()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .denied:
            permissionDenied
        case .failed(let error):
            failed(error)
        case .idle, .running:
            cameraUI
        }
    }

    private var cameraUI: some View {
        VStack(spacing: 0) {
            previewArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlBar
                .padding(.vertical, 24)
                .padding(.horizontal, 32)
        }
    }

    private var previewArea: some View {
        ZStack {
            MetalCIPreviewView(image: pipeline?.previewImage)
                .background(Color.black)

            CameraGestureLayer(
                onSingleTap: { location, size in handleTap(at: location, in: size) },
                onDoubleTap: { session.switchCamera() },
                onLongPressChange: { pressing in isBoosting = pressing }
            )

            if let indicator = focusIndicator {
                FocusReticle()
                    .position(indicator.location)
                    .transition(.opacity)
                    .id(indicator.id)
                    .allowsHitTesting(false)
            }

            if isBoosting {
                boostBadge
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) { qualityButton.padding(12) }
        .overlay(alignment: .bottomTrailing) { fpsBadge.padding(12) }
        .overlay(alignment: .bottom) { lensSwitcher.padding(.bottom, 12) }
    }

    @ViewBuilder
    private var lensSwitcher: some View {
        if session.position == .front {
            // Front camera has no zoom dial — just a single toggle for wide
            // vs. normal selfie framing, matching iOS Camera.
            frontFramingToggle
        } else if lensSnapPoints.count >= 2 {
            ZoomDialView(
                displayZoom: displayZoom,
                lensSnapPoints: lensSnapPoints,
                displayRange: displayRange,
                onZoomChanged: { newDisplay in
                    session.setZoom(newDisplay * baseRaw)
                }
            )
        }
    }

    private var frontFramingToggle: some View {
        Button {
            frontWide.toggle()
            applyFrontFraming()
        } label: {
            Image(systemName: frontWide
                  ? "arrow.up.right.and.arrow.down.left"
                  : "arrow.down.left.and.arrow.up.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(frontWide ? .yellow : .white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.black.opacity(0.5)))
        }
        .accessibilityLabel(frontWide ? "Standard framing" : "Wide framing")
    }

    private func applyFrontFraming() {
        guard session.position == .front else { return }
        let target = frontWide ? session.minZoomFactor : (session.minZoomFactor * frontNormalZoom)
        session.setZoom(target)
    }

    private var baseRaw: CGFloat {
        session.lensSwitchFactors.first ?? 1.0
    }

    private var displayZoom: CGFloat {
        session.zoomFactor / baseRaw
    }

    private var displayRange: ClosedRange<CGFloat> {
        let lo = session.minZoomFactor / baseRaw
        let hi = session.maxZoomFactor / baseRaw
        return lo...hi
    }

    // One snap point per *physical* lens — the digital 2× crop is reachable
    // through long-press + drag on the wheel, not as a button (matches iOS
    // Camera). For the dual-wide back camera this yields [.5, 1]; for the
    // triple back camera [.5, 1, 3]; for a single wide just [1].
    private var lensSnapPoints: [CGFloat] {
        var points: [CGFloat] = [session.minZoomFactor / baseRaw]
        for switchFactor in session.lensSwitchFactors {
            points.append(switchFactor / baseRaw)
        }
        return points
    }

    @ViewBuilder
    private var fpsBadge: some View {
        if let duration = pipeline?.lastFrameDuration, duration > 0 {
            iOSStylePill(value: "\(Int(round(1.0 / duration)))", label: "FPS")
        }
    }

    private var boostBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
            Text("BOOST")
                .tracking(0.5)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.yellow.opacity(0.95), in: Capsule())
    }

    private var qualityButton: some View {
        Menu {
            ForEach(LivePreviewQuality.allCases) { q in
                Button {
                    previewQualityRaw = q.rawValue
                } label: {
                    if q == previewQuality {
                        Label(q.label, systemImage: "checkmark")
                    } else {
                        Label(q.label, systemImage: q.systemImage)
                    }
                }
            }
        } label: {
            let inner = Image(systemName: previewQuality.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
                .rotationEffect(iconRotation)

            inner
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.5), in: Capsule())
        }
        .accessibilityLabel("Preview quality: \(previewQuality.label)")
    }

    // iOS Photos style pill: outer capsule stays wide-horizontal in screen
    // coordinates regardless of device orientation. The inner text group is
    // rearranged (inline → stacked) AND rotated as a single piece so the
    // text reads upright to a user holding the device in either orientation.
    @ViewBuilder
    private func iOSStylePill(value: String, label: String) -> some View {
        ZStack {
            if orientation.orientation.isLandscape {
                VStack(spacing: -2) {
                    Text(value)
                        .font(.system(size: 18, weight: .semibold))
                    Text(label)
                        .font(.system(size: 9, weight: .regular))
                }
                .fixedSize()
                .rotationEffect(iconRotation)
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 18, weight: .semibold))
                    Text(label)
                        .font(.system(size: 10, weight: .regular))
                        .baselineOffset(7)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(width: 64, height: 30)
        .background(.black.opacity(0.5), in: Capsule())
    }

    private var controlBar: some View {
        HStack {
            thumbnailButton
                .frame(width: 44, height: 44)

            Spacer()

            Button {
                shutter()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 4)
                        .frame(width: 72, height: 72)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 58, height: 58)
                    if isCapturing {
                        ProgressView()
                            .tint(.black)
                    }
                }
            }
            .disabled(isCapturing || session.latestImage == nil)
            .accessibilityLabel("Shutter")

            Spacer()

            Button {
                session.switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .rotationEffect(iconRotation)
            }
            .accessibilityLabel("Flip camera")
        }
    }

    @ViewBuilder
    private var thumbnailButton: some View {
        // Show the most recent successfully sent dithered image — what was
        // actually pushed to the e-paper, not the raw source. Tap routes the
        // user into the Photos tab (history view); long-press jumps straight
        // back into Composer to re-tune that entry.
        if let recent = historyStore.mostRecentSent(),
           let dither = recent.loadImage(.dither) ?? recent.loadImage(.thumb) {
            Button {
                onTapHistoryThumb()
            } label: {
                Image(uiImage: dither)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.7), lineWidth: 1)
                    }
                    .rotationEffect(iconRotation)
            }
            .accessibilityLabel("Open photo library")
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in onLongPressHistoryThumb(recent) }
            )
        } else {
            Color.clear
        }
    }

    private var permissionDenied: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Camera access is required")
                .font(.headline)
            Text("Enable camera access in Settings to use the live dither preview.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }

    private func failed(_ error: any Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("Camera failed to start")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .foregroundStyle(.white)
    }

    private func shutter() {
        guard !isCapturing, let pipeline else {
            logger.error("shutter aborted: missing pipeline")
            return
        }
        isCapturing = true
        Task {
            defer { isCapturing = false }

            // AVCapturePhotoOutput delivers the device's full-sensor still
            // (e.g. 12MP on iPhone 12 mini back wide) regardless of the
            // session's video preset. Falls back to a snapshot of the live
            // frame on failure.
            if let data = await session.capturePhoto(),
               let baseCI = CIImage(data: data),
               let baseUI = UIImage(data: data)
            {
                let oriented = baseCI.oriented(forExifOrientation: exifOrientation(of: data))
                let cropped = pipeline.croppedToDisplayAspect(oriented)
                _ = baseUI  // source is preserved via the HistoryEntry auto-draft in Composer
                onCapture(cropped)
            } else if let source = session.latestImage {
                let cropped = pipeline.croppedToDisplayAspect(source)
                let context = CIContext()
                guard let cg = context.createCGImage(cropped, from: cropped.extent) else { return }
                let snapCI = CIImage(cgImage: cg)
                onCapture(snapCI)
            }
        }
    }

    private func exifOrientation(of data: Data) -> Int32 {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let value = properties[kCGImagePropertyOrientation] as? UInt32
        else { return 1 }
        return Int32(value)
    }

    private func handleTap(at location: CGPoint, in size: CGSize) {
        let normalized = CGPoint(
            x: max(0, min(1, location.x / size.width)),
            y: max(0, min(1, location.y / size.height))
        )
        let cameraPoint = CGPoint(x: normalized.y, y: 1 - normalized.x)
        session.focus(atNormalized: cameraPoint)

        let indicator = FocusIndicator(location: location)
        withAnimation(.easeOut(duration: 0.15)) {
            focusIndicator = indicator
        }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            await MainActor.run {
                if focusIndicator?.id == indicator.id {
                    withAnimation(.easeIn(duration: 0.4)) {
                        focusIndicator = nil
                    }
                }
            }
        }
    }
}

private struct FocusReticle: View {
    @State private var pulse: Bool = false

    var body: some View {
        Rectangle()
            .strokeBorder(Color.yellow, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .scaleEffect(pulse ? 1.0 : 1.3)
            .opacity(pulse ? 0.9 : 0.4)
            .animation(.easeOut(duration: 0.25), value: pulse)
            .onAppear { pulse = true }
    }
}
