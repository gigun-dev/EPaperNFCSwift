//
//  OrientationObserver.swift
//  EPaperNFCDemo
//

import SwiftUI
import UIKit

@MainActor
@Observable
final class OrientationObserver {
    private(set) var orientation: UIDeviceOrientation = UIDevice.current.orientation

    private var observer: NSObjectProtocol?
    private var subscribers: Int = 0

    var iconRotation: Angle {
        switch orientation {
        case .landscapeLeft: .degrees(90)
        case .landscapeRight: .degrees(-90)
        case .portraitUpsideDown: .degrees(180)
        default: .degrees(0)
        }
    }

    var videoRotationAngle: CGFloat {
        switch orientation {
        case .landscapeLeft: 0
        case .landscapeRight: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }

    func subscribe() {
        subscribers += 1
        guard subscribers == 1 else { return }
        if !UIDevice.current.isGeneratingDeviceOrientationNotifications {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        let current = UIDevice.current.orientation
        if current.isValidInterfaceOrientation {
            orientation = current
        }
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let new = UIDevice.current.orientation
                if new.isValidInterfaceOrientation && new != self.orientation {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        self.orientation = new
                    }
                }
            }
        }
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
    }
}
