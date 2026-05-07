//
//  HistoryStore.swift
//  EPaperNFCDemo
//
//  Domain model + persistence for "sent / drafted to e-paper" entries.
//  SwiftData stores metadata; image bytes live as files under
//  Application Support/Entries/{id}/ so we don't bloat the SwiftData store.
//

import EPaperNFCSwift
import Foundation
import OSLog
import SwiftData
import SwiftUI
import UIKit

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "HistoryStore"
)

// MARK: - Versioning

// Bump when the dither algorithm changes in a way that would alter pixel
// output for the same source + settings. Persisted entries record the
// version at write time so we can later detect "render is stale".
nonisolated enum DitherAlgorithmVersion {
    static let current: Int = 1
}

// Bump if the palette color values change.
nonisolated enum PaletteVersion {
    static let current: Int = 1
}

// Bump if RenderSettings gets new fields. Old entries decode with defaults.
nonisolated enum RenderSettingsVersion {
    static let current: Int = 1
}

// MARK: - Value types

nonisolated enum EntrySource: String, Codable, Sendable {
    case camera, photos, shareIn, openIn, demoImage
}

nonisolated enum EntryStatus: String, Codable, Sendable {
    case draft           // captured / picked but not yet sent
    case sent            // last send attempt succeeded
    case failedLastSend  // had a successful send earlier OR still trying — last attempt failed
}

nonisolated struct RenderSettings: Codable, Equatable, Hashable, Sendable {
    var sCurveStrength: Float
    var unsharpRadius: Float
    var unsharpIntensity: Float
    var version: Int

    init(
        sCurveStrength: Float,
        unsharpRadius: Float,
        unsharpIntensity: Float,
        version: Int = RenderSettingsVersion.current
    ) {
        self.sCurveStrength = sCurveStrength
        self.unsharpRadius = unsharpRadius
        self.unsharpIntensity = unsharpIntensity
        self.version = version
    }
}

// Stable identifier for a DisplayType — encodes the four discriminating
// fields. Used both as a SwiftData column and to round-trip back to a
// DisplayType via lookup.
nonisolated struct DisplayTypeKey: Codable, Equatable, Hashable, Sendable {
    var width: Int
    var height: Int
    var paletteRaw: String      // "bw" | "bwyr"
    var orientationRaw: String  // "normal" | "rotated" | "flipped"

    static func from(_ dt: DisplayType) -> DisplayTypeKey {
        DisplayTypeKey(
            width: dt.width,
            height: dt.height,
            paletteRaw: paletteString(dt.colorPalette),
            orientationRaw: orientationString(dt.orientation)
        )
    }

    func resolve() -> DisplayType? {
        DisplayType.allDisplayTypes.first { DisplayTypeKey.from($0) == self }
    }

    private static func paletteString(_ p: DisplayType.ColorPalette) -> String {
        switch p {
        case .blackAndWhite: "bw"
        case .blackWhiteYellowRed: "bwyr"
        }
    }

    private static func orientationString(_ o: DisplayType.Orientation) -> String {
        switch o {
        case .normal: "normal"
        case .rotated: "rotated"
        case .flipped: "flipped"
        }
    }
}

// MARK: - SwiftData model

@Model
final class HistoryEntry {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var sentAt: Date?
    var favorite: Bool
    var sourceRaw: String
    var statusRaw: String

    // Display target (encoded as DisplayTypeKey fields, flattened for queryability)
    var displayWidth: Int
    var displayHeight: Int
    var displayPaletteRaw: String
    var displayOrientationRaw: String

    // Render settings (flattened)
    var sCurveStrength: Float
    var unsharpRadius: Float
    var unsharpIntensity: Float
    var renderSettingsVersion: Int

    // Versioning
    var algorithmVersion: Int
    var paletteVersion: Int

    // Optional last error description (set when statusRaw == failedLastSend).
    var lastErrorDescription: String?

    // PHAsset.localIdentifier when imported from the system library. Lets us
    // dedupe / toggle (vs. duplicate) when the user re-favorites the same
    // library photo from LibraryBrowserView.
    var assetLocalIdentifier: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        source: EntrySource,
        status: EntryStatus,
        displayType: DisplayType,
        renderSettings: RenderSettings
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.sentAt = nil
        self.favorite = false
        self.sourceRaw = source.rawValue
        self.statusRaw = status.rawValue

        let key = DisplayTypeKey.from(displayType)
        self.displayWidth = key.width
        self.displayHeight = key.height
        self.displayPaletteRaw = key.paletteRaw
        self.displayOrientationRaw = key.orientationRaw

        self.sCurveStrength = renderSettings.sCurveStrength
        self.unsharpRadius = renderSettings.unsharpRadius
        self.unsharpIntensity = renderSettings.unsharpIntensity
        self.renderSettingsVersion = renderSettings.version

        self.algorithmVersion = DitherAlgorithmVersion.current
        self.paletteVersion = PaletteVersion.current
    }
}

extension HistoryEntry {
    var source: EntrySource {
        get { EntrySource(rawValue: sourceRaw) ?? .photos }
        set { sourceRaw = newValue.rawValue }
    }

    var status: EntryStatus {
        get { EntryStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    var displayTypeKey: DisplayTypeKey {
        DisplayTypeKey(
            width: displayWidth,
            height: displayHeight,
            paletteRaw: displayPaletteRaw,
            orientationRaw: displayOrientationRaw
        )
    }

    var renderSettings: RenderSettings {
        get {
            RenderSettings(
                sCurveStrength: sCurveStrength,
                unsharpRadius: unsharpRadius,
                unsharpIntensity: unsharpIntensity,
                version: renderSettingsVersion
            )
        }
        set {
            sCurveStrength = newValue.sCurveStrength
            unsharpRadius = newValue.unsharpRadius
            unsharpIntensity = newValue.unsharpIntensity
            renderSettingsVersion = newValue.version
        }
    }
}

// MARK: - File layout

// Each entry owns a directory under Application Support. Three image files
// live inside; presence is best-effort (entries can exist without all three
// while a draft is being authored).
nonisolated enum EntryFile: String {
    case dither = "dither.png"          // 400x300 etc., palette-rendered RGB
    case source = "source.jpg"          // user's source image, long-edge limited
    case thumb = "thumb.jpg"            // small thumb for grid + camera bottom-left
}

nonisolated enum EntryFileLayout {
    static let entriesRootName = "Entries"
    static let sourceLongEdgeMax: CGFloat = 2048
    static let thumbLongEdgeMax: CGFloat = 320
    static let sourceJPEGQuality: CGFloat = 0.85
    static let thumbJPEGQuality: CGFloat = 0.8

    static func entriesRoot() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent(entriesRootName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    static func directory(for id: UUID) throws -> URL {
        let dir = try entriesRoot().appendingPathComponent(id.uuidString, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func url(_ file: EntryFile, for id: UUID) throws -> URL {
        try directory(for: id).appendingPathComponent(file.rawValue)
    }

    static func remove(id: UUID) {
        do {
            let dir = try directory(for: id)
            try FileManager.default.removeItem(at: dir)
        } catch {
            logger.error("Failed to remove entry directory: \(String(describing: error))")
        }
    }
}

// MARK: - Store

// Thin facade around the SwiftData ModelContainer + file ops. Owns the
// container lifetime; `shared` is set up by MainApp.
@MainActor
@Observable
final class HistoryStore {
    static let shared: HistoryStore = {
        do {
            return try HistoryStore()
        } catch {
            logger.error("HistoryStore failed to initialize: \(String(describing: error)) — falling back to in-memory")
            // In-memory fallback so the app still runs even if disk is broken.
            return (try? HistoryStore(inMemory: true)) ?? HistoryStore.unsafeInMemory()
        }
    }()

    let container: ModelContainer
    private let context: ModelContext

    init(inMemory: Bool = false) throws {
        let schema = Schema([HistoryEntry.self])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        self.container = try ModelContainer(for: schema, configurations: [config])
        // Use the container's main context — the same one SwiftUI's @Query
        // observes via .modelContainer(...). Creating a separate ModelContext
        // here would mean inserts/deletes go to one context while the UI's
        // @Query observes another, and changes won't auto-propagate to the
        // grid (causing "deleted entry's placeholder remains" and similar
        // staleness bugs).
        self.context = container.mainContext
    }

    // Last-resort: force-create an in-memory container without throwing.
    private static func unsafeInMemory() -> HistoryStore {
        // swiftlint:disable:next force_try
        try! HistoryStore(inMemory: true)
    }

    // MARK: queries

    func fetchAll(favoritesOnly: Bool = false) -> [HistoryEntry] {
        var descriptor = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        if favoritesOnly {
            descriptor.predicate = #Predicate<HistoryEntry> { $0.favorite == true }
        }
        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("HistoryStore.fetchAll failed: \(String(describing: error))")
            return []
        }
    }

    func mostRecentSent() -> HistoryEntry? {
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate<HistoryEntry> { $0.statusRaw == "sent" },
            sortBy: [SortDescriptor(\.sentAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func entry(id: UUID) -> HistoryEntry? {
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate<HistoryEntry> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func entry(forAssetID localIdentifier: String) -> HistoryEntry? {
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate<HistoryEntry> { $0.assetLocalIdentifier == localIdentifier }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: writes

    // Create a new entry and write any provided image data atomically.
    @discardableResult
    func record(
        source: EntrySource,
        status: EntryStatus,
        displayType: DisplayType,
        renderSettings: RenderSettings,
        ditherImage: UIImage?,
        sourceImage: UIImage?,
        sentAt: Date? = nil,
        errorDescription: String? = nil,
        assetLocalIdentifier: String? = nil
    ) -> HistoryEntry {
        let entry = HistoryEntry(
            source: source,
            status: status,
            displayType: displayType,
            renderSettings: renderSettings
        )
        entry.sentAt = sentAt
        entry.lastErrorDescription = errorDescription
        entry.assetLocalIdentifier = assetLocalIdentifier

        context.insert(entry)

        writeFiles(
            id: entry.id,
            ditherImage: ditherImage,
            sourceImage: sourceImage
        )

        save()
        return entry
    }

    // Update an existing entry's render settings + status, and rewrite its
    // image files. Used when re-sending from history with new tuning.
    func updateOnSendSuccess(
        _ entry: HistoryEntry,
        renderSettings: RenderSettings,
        ditherImage: UIImage?,
        sourceImage: UIImage?
    ) {
        entry.renderSettings = renderSettings
        entry.status = .sent
        entry.sentAt = Date()
        entry.updatedAt = Date()
        entry.lastErrorDescription = nil
        writeFiles(id: entry.id, ditherImage: ditherImage, sourceImage: sourceImage)
        save()
    }

    func setFavorite(_ entry: HistoryEntry, _ favorite: Bool) {
        entry.favorite = favorite
        entry.updatedAt = Date()
        save()
    }

    func delete(_ entry: HistoryEntry) {
        let id = entry.id
        context.delete(entry)
        do {
            try context.save()
        } catch {
            logger.error("HistoryStore.delete save failed: \(String(describing: error))")
        }
        EntryFileLayout.remove(id: id)
    }

    // One-shot cleanup of two pathologies introduced by earlier code paths:
    //  1) Pre-fix LibraryBrowserView ★ button created a new entry on every
    //     tap (no dedupe by assetLocalIdentifier yet) → many duplicates with
    //     status=.draft, favorite=true, assetLocalIdentifier=nil.
    //  2) Same asset can have multiple entries — keep the newest, drop rest.
    // Idempotent; safe to call repeatedly.
    // Wipe every entry's cached dither.png. Used to recover from the
    // earlier cross-contamination bug where multiple entries' dither files
    // ended up identical. Each entry will regenerate its dither on next
    // view via PhotoDetailView's renderFinalDither.
    func clearAllDitherCache() {
        for entry in fetchAll() {
            if let url = try? EntryFileLayout.url(.dither, for: entry.id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func cleanupDuplicates() {
        let entries = fetchAll()
        // (1) Drop the buggy fav drafts
        for entry in entries
        where entry.status == .draft
            && entry.favorite
            && entry.assetLocalIdentifier == nil {
            context.delete(entry)
            EntryFileLayout.remove(id: entry.id)
        }
        // (2) Per-asset dedupe — fetchAll is sorted by updatedAt desc, so we
        // keep the first seen and delete subsequent duplicates.
        var seen = Set<String>()
        for entry in fetchAll() {
            guard let aid = entry.assetLocalIdentifier else { continue }
            if seen.contains(aid) {
                context.delete(entry)
                EntryFileLayout.remove(id: entry.id)
            } else {
                seen.insert(aid)
            }
        }
        save()
    }

    func save() {
        do {
            try context.save()
        } catch {
            logger.error("HistoryStore.save failed: \(String(describing: error))")
        }
    }

    // MARK: file helpers

    private func writeFiles(
        id: UUID,
        ditherImage: UIImage?,
        sourceImage: UIImage?
    ) {
        if let ditherImage, let png = ditherImage.pngData() {
            writeAtomically(png, to: .dither, for: id)
        }
        if let sourceImage {
            let limited = downscale(sourceImage, longEdgeMax: EntryFileLayout.sourceLongEdgeMax)
            if let jpeg = limited.jpegData(compressionQuality: EntryFileLayout.sourceJPEGQuality) {
                writeAtomically(jpeg, to: .source, for: id)
            }
            let thumb = downscale(sourceImage, longEdgeMax: EntryFileLayout.thumbLongEdgeMax)
            if let thumbData = thumb.jpegData(compressionQuality: EntryFileLayout.thumbJPEGQuality) {
                writeAtomically(thumbData, to: .thumb, for: id)
            }
        } else if let ditherImage {
            // Fall back to a thumb derived from the dithered image — keeps
            // the camera bottom-left preview meaningful even if we never had
            // a source (e.g. demo image, or future capture-without-original).
            let thumb = downscale(ditherImage, longEdgeMax: EntryFileLayout.thumbLongEdgeMax)
            if let thumbData = thumb.jpegData(compressionQuality: EntryFileLayout.thumbJPEGQuality) {
                writeAtomically(thumbData, to: .thumb, for: id)
            }
        }
    }

    private func writeAtomically(_ data: Data, to file: EntryFile, for id: UUID) {
        do {
            let url = try EntryFileLayout.url(file, for: id)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to write \(file.rawValue) for \(id.uuidString): \(String(describing: error))")
        }
    }

    private func downscale(_ image: UIImage, longEdgeMax: CGFloat) -> UIImage {
        let size = image.size
        let longEdge = max(size.width, size.height)
        if longEdge <= longEdgeMax { return image }
        let scale = longEdgeMax / longEdge
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - Loading helpers

extension HistoryEntry {
    // Bypasses UIImage's internal data-signature cache by going through
    // CGImageSource and constructing UIImage with an explicit scale of 1.
    // Without this, two entries whose files happen to contain identical
    // bytes can return the SAME UIImage instance — and during a paged
    // swipe both pages render that single shared instance, looking like
    // "same image on both sides".
    func loadImage(_ file: EntryFile) -> UIImage? {
        guard let url = try? EntryFileLayout.url(file, for: id),
              let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}
