//
//  PhotosTabView.swift
//  EPaperNFCDemo
//
//  History gallery — captures + imports. Single chronological grid; tapping
//  a cell pushes PhotoDetailView, which can paginate horizontally between
//  adjacent entries. We do NOT enumerate the system Photos library here;
//  importing an external photo is an explicit action via the overflow menu.
//

import CoreImage
import EPaperNFCSwift
import OSLog
import PhotosUI
import SwiftData
import SwiftUI

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "PhotosTabView"
)

struct PhotosTabView: View {
    let displayType: DisplayType
    @Binding var sCurveStrength: Float
    @Binding var unsharpRadius: Float
    @Binding var unsharpIntensity: Float

    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HistoryEntry.updatedAt, order: .reverse)
    private var allEntries: [HistoryEntry]

    @State private var filter: GalleryFilter = .all
    @State private var selectedItem: PhotosPickerItem?
    @State private var isPickerPresented: Bool = false
    @State private var navItemID: String?

    private enum GalleryFilter: String, CaseIterable, Identifiable {
        case all, sent, favorites
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All"
            case .sent: "Sent"
            case .favorites: "Favorites"
            }
        }
    }

    var body: some View {
        Group {
            if visible.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationDestination(item: $navItemID) { id in
            PhotoDetailView(
                displayType: displayType,
                sCurveStrength: $sCurveStrength,
                unsharpRadius: $unsharpRadius,
                unsharpIntensity: $unsharpIntensity,
                currentItemID: id
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { overflowMenu }
        }
        .photosPicker(isPresented: $isPickerPresented, selection: $selectedItem, matching: .images)
        .onChange(of: selectedItem) { _, item in
            guard let item else { return }
            Task { await importPicked(item) }
        }
    }

    private var visible: [HistoryEntry] {
        switch filter {
        case .all: allEntries
        case .sent: allEntries.filter { $0.status == .sent }
        case .favorites: allEntries.filter { $0.favorite }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 2)],
                spacing: 2
            ) {
                ForEach(visible) { entry in
                    Button {
                        navItemID = entry.id.uuidString
                    } label: {
                        ThumbnailCell(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenu(for: entry) }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: HistoryEntry) -> some View {
        Button {
            navItemID = entry.id.uuidString
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        Button {
            historyStore.setFavorite(entry, !entry.favorite)
        } label: {
            Label(
                entry.favorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: entry.favorite ? "star.slash" : "star"
            )
        }
        if let ui = entry.loadImage(.source) {
            Button {
                Task { await PhotoLibrarySaver.save(ui) }
            } label: {
                Label("Export Original to Photos", systemImage: "square.and.arrow.down")
            }
        }
        Divider()
        Button(role: .destructive) {
            let id = entry.id
            modelContext.delete(entry)
            try? modelContext.save()
            EntryFileLayout.remove(id: id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: filter == .favorites ? "star" : "camera.viewfinder")
                .resizable().scaledToFit()
                .frame(width: 72, height: 72)
                .foregroundStyle(.tint).symbolRenderingMode(.hierarchical)
            Text(emptyTitle).font(.title3.weight(.semibold))
            Text(emptySubtitle)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            if filter == .all {
                Button {
                    isPickerPresented = true
                } label: {
                    Label("Import Photo", systemImage: "photo.stack")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .padding(.horizontal, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch filter {
        case .favorites: "No favorites yet"
        case .sent: "Nothing sent yet"
        case .all: "No photos yet"
        }
    }

    private var emptySubtitle: String {
        switch filter {
        case .favorites: "Long-press a photo and choose Add to Favorites."
        case .sent: "Photos appear here once you send them to the e-paper."
        case .all: "Snap a photo on the Camera tab or import one to get started."
        }
    }

    private var overflowMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach(GalleryFilter.allCases) { f in
                    Label(f.label, systemImage: filterIcon(for: f)).tag(f)
                }
            }
            Divider()
            Button {
                isPickerPresented = true
            } label: {
                Label("Import from Library…", systemImage: "photo.stack")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }

    private func filterIcon(for f: GalleryFilter) -> String {
        switch f {
        case .all: "photo.on.rectangle"
        case .sent: "paperplane"
        case .favorites: "star"
        }
    }

    private func importPicked(_ item: PhotosPickerItem) async {
        defer { selectedItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let cg = UIImage(data: data)?.cgImage
            else { return }
            let ui = UIImage(cgImage: cg)
            let settings = RenderSettings(
                sCurveStrength: sCurveStrength,
                unsharpRadius: unsharpRadius,
                unsharpIntensity: unsharpIntensity
            )
            let entry = historyStore.record(
                source: .photos,
                status: .draft,
                displayType: displayType,
                renderSettings: settings,
                ditherImage: nil,
                sourceImage: ui
            )
            navItemID = entry.id.uuidString
            // Render initial dither in background so the entry shows with
            // the filter applied in the grid even before the user opens
            // detail or sends it. renderInitialDitherIfMissing touches
            // updatedAt at the end so @Query auto-refreshes.
            let entryID = entry.id
            let dt = displayType
            Task.detached(priority: .utility) {
                await renderInitialDitherIfMissing(entryID: entryID, displayType: dt, settings: settings)
            }
        } catch {
            logger.error(error)
        }
    }
}

@MainActor
private struct ThumbnailCell: View {
    let entry: HistoryEntry

    var body: some View {
        // Grid is the history of e-paper outputs, so the dither IS the
        // representative image. Drafts haven't been dithered yet — fall back
        // to source/thumb so the cell still has content.
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let ui = entry.loadImage(.dither) ?? entry.loadImage(.thumb) ?? entry.loadImage(.source) {
                    Image(uiImage: ui)
                        .resizable()
                        .interpolation(entry.loadImage(.dither) != nil ? .none : .high)
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                badges.padding(6)
            }
            .clipped()
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 3) {
            if entry.status == .sent {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.green.opacity(0.9), in: Circle())
            }
            if entry.favorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .padding(3)
                    .background(.black.opacity(0.55), in: Circle())
            }
        }
    }
}
