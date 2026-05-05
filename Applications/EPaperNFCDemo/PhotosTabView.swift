//
//  PhotosTabView.swift
//  EPaperNFCDemo
//

import CoreImage
import EPaperNFCSwift
import OSLog
import PhotosUI
import SwiftUI

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "PhotosTabView"
)

struct PhotosTabView: View {
    let displayType: DisplayType
    var onPick: (CIImage) -> Void

    @State private var selectedItem: PhotosPickerItem?
    @State private var isLoading: Bool = false
    @State private var loadError: (any Error)?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "photo.on.rectangle.angled")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text("Pick a photo to send")
                    .font(.title3.weight(.semibold))
                Text("Choose any image from your library — it will be dithered for the e-paper.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            PhotosPicker(
                selection: $selectedItem,
                matching: .images
            ) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(isLoading ? "Loading…" : "Pick Photo")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .disabled(isLoading)

            if loadError != nil {
                Text("Failed to load image.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .onChange(of: selectedItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let ciImage = CIImage(data: data)
            else {
                throw ImageError.failedToLoad
            }
            let oriented = ciImage.oriented(forExifOrientation: data.exifOrientation)

            // Match camera shutter behavior: rotate to match display
            // orientation, then crop to display aspect. The composer will
            // scaleToFill into the display extent.
            let displaySize = CGSize(width: displayType.width, height: displayType.height)
            let imageIsPortrait = oriented.extent.height > oriented.extent.width
            let displayIsPortrait = displaySize.height > displaySize.width
            let rotated = imageIsPortrait == displayIsPortrait
                ? oriented
                : oriented.oriented(.right)

            let cropped = centerCropToAspect(rotated, aspect: CGFloat(displayType.width) / CGFloat(displayType.height))
            onPick(cropped)
            // Reset selection so the same picture can be picked again.
            selectedItem = nil
        } catch {
            logger.error(error)
            loadError = error
        }
    }
}

private enum ImageError: Error {
    case failedToLoad
}

private extension Data {
    var exifOrientation: Int32 {
        guard let imageSource = CGImageSourceCreateWithData(self as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? UInt32
        else {
            return 1
        }
        return Int32(orientation)
    }
}

private func centerCropToAspect(_ image: CIImage, aspect displayAspect: CGFloat) -> CIImage {
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return image }
    let imageAspect = extent.width / extent.height
    let crop: CGRect
    if imageAspect > displayAspect {
        let targetWidth = extent.height * displayAspect
        let dx = (extent.width - targetWidth) / 2
        crop = CGRect(x: extent.origin.x + dx, y: extent.origin.y, width: targetWidth, height: extent.height)
    } else {
        let targetHeight = extent.width / displayAspect
        let dy = (extent.height - targetHeight) / 2
        crop = CGRect(x: extent.origin.x, y: extent.origin.y + dy, width: extent.width, height: targetHeight)
    }
    return image.cropped(to: crop)
}
