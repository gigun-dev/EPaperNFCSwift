//
//  ImageSourceView.swift
//  EPaperNFCDemo
//
//  Created by Yoshimasa Niwa on 2/20/26.
//

import CoreImage
import EPaperNFCSwift
import Foundation
import OSLog
import PhotosUI
import SwiftUI
import UIKit

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "ImageSourceView"
)

enum ImageError: Error {
    case failedToLoad
    case failedToRender
}

private extension CIImage {
    @concurrent
    func renderUIImage() async throws -> UIImage {
        if let cgImage {
            return UIImage(cgImage: cgImage)
        }

        guard let cgImage = CIContext().createCGImage(self, from: extent) else {
            throw ImageError.failedToRender
        }

        return UIImage(cgImage: cgImage)
    }
}

private extension Data {
    var exifOrientation: Int32 {
        guard let imageSource = CGImageSourceCreateWithData(self as CFData, nil) else {
            return 1
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? UInt32
        else {
            return 1
        }

        return Int32(orientation)
    }
}

private extension PhotosPickerItem {
    func loadCIImage() async throws -> CIImage {
        guard let data = try? await self.loadTransferable(type: Data.self),
              let ciImage = CIImage(data: data)
        else {
            throw ImageError.failedToLoad
        }

        return ciImage.oriented(forExifOrientation: data.exifOrientation)
    }
}

private extension DisplayType {
    var size: CGSize {
        CGSize(width: width, height: height)
    }
}

private enum ImageSource: Hashable, Identifiable, CaseIterable {
    case demoImage
    case photoLibrary

    var id: Self {
        self
    }

    var localizedName: LocalizedStringKey {
        switch self {
        case .demoImage:
            "Demo Image"
        case .photoLibrary:
            "Photo Library"
        }
    }
}

private struct StateTuple: Equatable {
    var displayType: DisplayType
    var imageSource: ImageSource
    var selectedPhotoItem: PhotosPickerItem?
}

struct ImageSectionView: View {
    var displayType: DisplayType

    @State
    private var imageSource: ImageSource = .demoImage

    @State
    private var isPhotosPickerPresented: Bool = false
    @State
    private var selectedPhotoItem: PhotosPickerItem?

    @State
    private var updateTask: Task<Void, Never>? = nil
    @State
    private var previewImage: UIImage?

    @Binding
    var image: EPaperNFCSwift.Image?

    var body: some View {
        Picker("Source", selection: $imageSource) {
            ForEach(ImageSource.allCases) { imageSource in
                Text(imageSource.localizedName)
                    .tag(imageSource)
            }
        }
        .onChange(of: StateTuple(
            displayType: displayType,
            imageSource: imageSource,
            selectedPhotoItem: selectedPhotoItem
        ), initial: true) { _, newValue in
            switch newValue.imageSource {
            case .demoImage:
                updateTask?.cancel()

                image = nil
                previewImage = nil

                updateTask = Task {
                    do {
                        let demoImage = EPaperNFCSwift.Image.demoImage(for: newValue.displayType)
                        let previewUIImage = try await demoImage.renderCIImage().renderUIImage()

                        if Task.isCancelled {
                            return
                        }

                        image = demoImage
                        previewImage = previewUIImage
                    } catch {
                        logger.error(error)
                    }
                    updateTask = nil
                }

            case .photoLibrary:
                if let selectedPhotoItem = newValue.selectedPhotoItem {
                    updateTask?.cancel()

                    image = nil
                    previewImage = nil

                    updateTask = Task {
                        do {
                            let ciImage = try await selectedPhotoItem.loadCIImage()

                            if Task.isCancelled {
                                return
                            }

                            let scaled = ciImage.scaled(
                                contentMode: .scaleToFit(backgroundColor: .white),
                                size: displayType.size
                            )
                            let ditheredData = await scaled.atkinsonDithered(for: displayType.colorPalette)
                            let ditheredImage = try EPaperNFCSwift.Image(data: ditheredData, for: displayType)
                            let previewUIImage = try await ditheredImage.renderCIImage().renderUIImage()

                            if Task.isCancelled {
                                return
                            }

                            image = ditheredImage
                            previewImage = previewUIImage
                        } catch {
                            logger.error(error)
                        }
                        updateTask = nil
                    }
                }
            }
        }
        .disabled(updateTask != nil)
        .onChange(of: imageSource) { _, newValue in
            if case .photoLibrary = imageSource {
                selectedPhotoItem = nil
                isPhotosPickerPresented = true
            }
        }
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $selectedPhotoItem,
            matching: .images
        )
        .onChange(of: isPhotosPickerPresented) { _, newValue in
            if !isPhotosPickerPresented, selectedPhotoItem == nil {
                imageSource = .demoImage
            }
        }

        if updateTask != nil {
            LabeledContent {
                ProgressView()
                    .controlSize(.small)
                    .id(NSObject())
            } label: {
                Text("Processing…")
            }
        }

        if let previewImage {
            HStack {
                Spacer()
                Image(uiImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 300.0)
                Spacer()
            }
        }

        if case .photoLibrary = imageSource {
            Button {
                isPhotosPickerPresented = true
            } label: {
                Text("Select Photo")
            }
            .disabled(updateTask != nil)
        }
    }
}

#Preview {
    @Previewable
    @State
    var image: EPaperNFCSwift.Image?

    Form {
        Section("Preview") {
            ImageSectionView(
                displayType: .fourPointTwoInchBlackWhiteYellowRed,
                image: $image
            )
        }
    }
}
