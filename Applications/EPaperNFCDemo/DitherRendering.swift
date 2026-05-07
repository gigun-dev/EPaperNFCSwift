//
//  DitherRendering.swift
//  EPaperNFCDemo
//
//  Pure helpers shared between camera, picker, history detail, and the
//  initial-draft background render. None of these touch SwiftUI state, so
//  they live as nonisolated free functions to be safely callable from any
//  actor or detached task.
//

import CoreGraphics
import CoreImage
import EPaperNFCSwift
import Foundation
import ImageIO
import UIKit

// MARK: - Image loading

// Decodes the file at `url` through CGImageSourceCreateWithData and returns
// a fresh UIImage with explicit scale=1. Going through CGImageSource avoids
// UIImage(data:)'s data-signature cache, which can hand out the same UIImage
// instance for two entries whose pixels happen to match — the cause of the
// "same image on both sides" swipe bug.
nonisolated func loadFreshUIImage(from url: URL?) -> UIImage? {
    guard let url,
          let data = try? Data(contentsOf: url),
          let src = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }
    return UIImage(cgImage: cg, scale: 1, orientation: .up)
}

// MARK: - Cropping

// Center-crops a CIImage to a given aspect ratio. Used both for the live
// preview path and the final hardware render.
nonisolated func centerCropToAspect(_ image: CIImage, aspect displayAspect: CGFloat) -> CIImage {
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

// Rotates a UIImage so portrait/landscape matches the display, then crops
// to the display aspect, then renders to a UIImage with scale=1.
nonisolated func cropToDisplayAspect(_ ui: UIImage, displayType: DisplayType) -> UIImage {
    guard let cg = ui.cgImage else { return ui }
    let ci = CIImage(cgImage: cg)
    let displaySize = CGSize(width: displayType.width, height: displayType.height)
    let imagePortrait = ci.extent.height > ci.extent.width
    let displayPortrait = displaySize.height > displaySize.width
    let oriented = imagePortrait == displayPortrait ? ci : ci.oriented(.right)
    let cropped = centerCropToAspect(
        oriented,
        aspect: CGFloat(displayType.width) / CGFloat(displayType.height)
    )
    guard let outCG = CIContext().createCGImage(cropped, from: cropped.extent) else { return ui }
    return UIImage(cgImage: outCG, scale: 1, orientation: .up)
}

// MARK: - Initial draft dither

// Renders a dither for a freshly-created entry and writes it to its
// .dither.png file so drafts (camera captures, picker imports) display
// with the filter applied immediately in the gallery grid — without the
// user having to open detail or hit Send first.
nonisolated func renderInitialDitherIfMissing(
    entryID: UUID,
    displayType: DisplayType,
    settings: RenderSettings
) async {
    let ditherURL = try? EntryFileLayout.url(.dither, for: entryID)
    if let ditherURL, FileManager.default.fileExists(atPath: ditherURL.path) {
        return
    }
    let sourceURL = try? EntryFileLayout.url(.source, for: entryID)
    guard let raw = loadFreshUIImage(from: sourceURL),
          let cg = raw.cgImage
    else { return }
    let ci = CIImage(cgImage: cg)
    let displaySize = CGSize(width: displayType.width, height: displayType.height)
    let imagePortrait = ci.extent.height > ci.extent.width
    let displayPortrait = displaySize.height > displaySize.width
    let oriented = imagePortrait == displayPortrait ? ci : ci.oriented(.right)
    let cropped = centerCropToAspect(
        oriented,
        aspect: CGFloat(displayType.width) / CGFloat(displayType.height)
    )
    let scaled = cropped.scaled(contentMode: .scaleToFill, size: displaySize)
    let data = await scaled.atkinsonDithered(
        for: displayType.colorPalette,
        sCurveStrength: settings.sCurveStrength,
        unsharpRadius: settings.unsharpRadius,
        unsharpIntensity: settings.unsharpIntensity
    )
    guard let image = try? EPaperNFCSwift.Image(data: data, for: displayType) else { return }
    let outCI = await image.renderCIImage()
    guard let outCG = outCI.cgImage ?? CIContext().createCGImage(outCI, from: outCI.extent) else { return }
    let outUI = UIImage(cgImage: outCG, scale: 1, orientation: .up)
    guard let png = outUI.pngData(), let url = ditherURL else { return }
    try? png.write(to: url, options: .atomic)
    // Touch updatedAt so SwiftUI @Query observers re-fetch and the grid
    // repaints with the now-available dither file.
    await MainActor.run {
        if let entry = HistoryStore.shared.entry(id: entryID) {
            entry.updatedAt = Date()
            HistoryStore.shared.save()
        }
    }
}
