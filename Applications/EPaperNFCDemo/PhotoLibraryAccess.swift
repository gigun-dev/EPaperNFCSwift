//
//  PhotoLibraryAccess.swift
//  EPaperNFCDemo
//
//  Owns the read-side authorization state for the user's Photos library.
//  Saving images is handled separately via UIImageWriteToSavedPhotosAlbum
//  (see ios26_photos_kvo_bug.md for why we don't use PHAssetCreationRequest).
//

import Foundation
import OSLog
import Photos
import SwiftUI

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "PhotoLibraryAccess"
)

@MainActor
@Observable
final class PhotoLibraryAccess {
    static let shared = PhotoLibraryAccess()

    private(set) var status: PHAuthorizationStatus

    init() {
        self.status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // Triggers the OS prompt the first time. Subsequent calls just return
    // the current status.
    @discardableResult
    func requestAuthorization() async -> PHAuthorizationStatus {
        let new = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        self.status = new
        return new
    }

    func refresh() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var isReadable: Bool {
        switch status {
        case .authorized, .limited: true
        default: false
        }
    }
}
