//
//  CameraInteractions.swift
//  EPaperNFCDemo
//
//  Glue between SwiftUI and UIKit-only APIs we need on the camera screen:
//  hardware-volume shutter, press-and-hold gesture for the quality boost,
//  and the Photos library write helper for saving the captured frame.
//

import AVKit
import CoreImage
import OSLog
import Photos
import SwiftUI
import UIKit

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "CameraInteractions"
)

// MARK: - Unified gesture layer (single tap + double tap + long press)

// All three gestures coexist on one UIView so SwiftUI's ZStack hit-testing
// doesn't make the upper view swallow touches before they reach the lower
// recognizers. Single tap waits for double-tap to fail; long press is
// configured to fire .began only after `minimumDuration` and to allow
// arbitrary movement so the user doesn't accidentally cancel boost by
// shifting their finger.
struct CameraGestureLayer: UIViewRepresentable {
    var onSingleTap: (CGPoint, CGSize) -> Void
    var onDoubleTap: () -> Void
    var onLongPressChange: (Bool) -> Void
    var longPressMinimumDuration: TimeInterval = 0.3

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleTap: onSingleTap,
            onDoubleTap: onDoubleTap,
            onLongPressChange: onLongPressChange
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        single.numberOfTapsRequired = 1
        view.addGestureRecognizer(single)

        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        view.addGestureRecognizer(double)
        single.require(toFail: double)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = longPressMinimumDuration
        longPress.allowableMovement = .greatestFiniteMagnitude
        view.addGestureRecognizer(longPress)

        for recognizer in [single, double, longPress] {
            recognizer.delegate = context.coordinator
            recognizer.cancelsTouchesInView = false
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onLongPressChange = onLongPressChange
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSingleTap: (CGPoint, CGSize) -> Void
        var onDoubleTap: () -> Void
        var onLongPressChange: (Bool) -> Void

        init(
            onSingleTap: @escaping (CGPoint, CGSize) -> Void,
            onDoubleTap: @escaping () -> Void,
            onLongPressChange: @escaping (Bool) -> Void
        ) {
            self.onSingleTap = onSingleTap
            self.onDoubleTap = onDoubleTap
            self.onLongPressChange = onLongPressChange
        }

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view)
            let size = recognizer.view?.bounds.size ?? .zero
            onSingleTap(location, size)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            onDoubleTap()
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onLongPressChange(true)
            case .ended, .cancelled, .failed:
                onLongPressChange(false)
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

// MARK: - Volume button shutter

struct VolumeShutterAttachment: UIViewRepresentable {
    var onShutter: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        if #available(iOS 17.2, *) {
            // AVCam sample fires on .ended (release) — matches iOS Camera's
            // own hardware-button behaviour and avoids double-firing.
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .ended { onShutter() }
            }
            interaction.isEnabled = true
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Photo library save

// PHPhotoLibrary.performChanges crashes in iOS 26.3's Photos framework
// internals — both the data-based addResource(with: .photo, data:) and the
// UIImage-based PHAssetChangeRequest.creationRequestForAsset(from:) routes
// trip a `PUPhotosFileProviderItemProvider` KVO observer that throws inside
// `NSDictionary allKeysForObject` on a concurrent mutation (verified via
// crash report). UIImageWriteToSavedPhotosAlbum is technically deprecated
// but still functional and uses an older code path that bypasses the buggy
// observer. Switch back to PhotoKit when Apple ships a fix.
enum PhotoLibrarySaver {
    @MainActor
    static func save(_ image: UIImage) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard granted == .authorized || granted == .limited else { return }
        case .restricted, .denied:
            return
        case .authorized, .limited:
            break
        @unknown default:
            return
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }
}
