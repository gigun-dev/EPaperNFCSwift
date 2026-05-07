//
//  PhotoDetailView.swift
//  EPaperNFCDemo
//
//  Photos.app-style detail for HistoryEntries. Pages render source from
//  the entry's stored source.jpg; the focused page overlays a live dither
//  preview. Long-press = compare against original. Edit splits the screen
//  so the preview stays visible while sliders move.
//

import CoreImage
import EPaperNFCSwift
import OSLog
import SwiftData
import SwiftUI
import UIKit

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "PhotoDetailView"
)

struct PhotoDetailView: View {
    let displayType: DisplayType
    @Binding var sCurveStrength: Float
    @Binding var unsharpRadius: Float
    @Binding var unsharpIntensity: Float

    @State var currentItemID: String

    @Environment(HistoryStore.self) private var historyStore
    @Environment(AnyEPaperNFCService.self) private var ePaperNFCService
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HistoryEntry.updatedAt, order: .reverse)
    private var allEntries: [HistoryEntry]

    @State private var pipeline: LiveDitherPipeline?
    @State private var loadTask: Task<Void, Never>?
    @State private var currentSource: UIImage?
    @State private var currentCropped: CIImage?
    @State private var pipelineEntryID: String?
    @State private var pageImageCache: [UUID: PageImages] = [:]
    @State private var ditheredImage: EPaperNFCSwift.Image?
    @State private var sendError: (any Error)?
    @State private var isSending: Bool = false
    @State private var isEditing: Bool = false
    @State private var isShowingSourceOverlay: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // Pager fills the remaining vertical space. When editing,
                // the panel claims its intrinsic height and the pager
                // shrinks accordingly — photo aspect-fits into the SHRUNK
                // area, eliminating the empty space above we used to leave.
                pager
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if !isEditing {
                            bottomActionBar
                        }
                    }

                if isEditing {
                    editPanel
                        .background(.regularMaterial)
                }
            }
        }
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { backButton }
            ToolbarItem(placement: .topBarTrailing) { favButton }
        }
        .task {
            ensurePipeline()
            await preloadVisible()
            await loadCurrent()
        }
        .onChange(of: currentItemID) { _, _ in
            Task {
                await preloadVisible()
                await loadCurrent()
            }
        }
        .onChange(of: TuneInputs(s: sCurveStrength, r: unsharpRadius, i: unsharpIntensity)) { _, _ in
            pipeline?.sCurveStrength = sCurveStrength
            pipeline?.unsharpRadius = unsharpRadius
            pipeline?.unsharpIntensity = unsharpIntensity
            if let cropped = currentCropped {
                Task { await renderFinalDither(cropped) }
            }
        }
    }

    // MARK: - Pager

    private var pager: some View {
        ZStack {
            Color.black

            // Native SwiftUI paging instead of TabView.page (which is a
            // UIPageViewController bridge with snapshot-based animation
            // and opaque view recycling — both of which were leaking the
            // previous entry's content onto the new page mid-swipe).
            // ScrollView + scrollTargetBehavior(.paging) keeps the view
            // identity model transparent: each ForEach iteration is its
            // own page, swiped to via native scroll.
            ScrollView(.horizontal, showsIndicators: false) {
                // Eager HStack — every page is realised up front, eliminating
                // LazyHStack's view-recycling window where the previous
                // entry's bytes could briefly appear in a recycled slot.
                // .compositingGroup forces each page into its own render
                // layer; .clipped guarantees no pixel of one page can paint
                // into the neighbour's slot regardless of what SwiftUI does
                // internally.
                LazyHStack(spacing: 0) {
                    ForEach(allEntries) { entry in
                        DetailPage(
                            images: pageImageCache[entry.id] ?? PageImages(),
                            isCurrent: entry.id.uuidString == currentItemID,
                            isEditing: isEditing,
                            ditherPreview: pipeline?.previewImage,
                            showSourceOnly: isShowingSourceOverlay
                        )
                        .containerRelativeFrame(.horizontal)
                        .id(entry.id.uuidString)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: scrollPositionBinding)
            .scrollDisabled(isEditing)

            if isShowingSourceOverlay {
                Text("Original")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 60)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    // Wraps currentItemID into the optional Binding shape that
    // scrollPosition(id:) expects.
    private var scrollPositionBinding: Binding<String?> {
        Binding(
            get: { currentItemID },
            set: { newValue in
                if let newValue, newValue != currentItemID {
                    currentItemID = newValue
                }
            }
        )
    }

    // MARK: - Bottom action bar (compact / non-edit mode)

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: isShowingSourceOverlay ? "rectangle.checkered" : "rectangle.on.rectangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isShowingSourceOverlay ? .yellow : .white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: Circle())
                .contentShape(Circle())
                .onLongPressGesture(
                    minimumDuration: 0.0,
                    maximumDistance: .infinity,
                    perform: {},
                    onPressingChanged: { pressing in
                        isShowingSourceOverlay = pressing
                    }
                )
                .accessibilityLabel("Press and hold to compare")

            roundButton(system: "slider.horizontal.3", tint: .white) {
                withAnimation(.easeInOut(duration: 0.2)) { isEditing = true }
            }
            .accessibilityLabel("Tune")

            Spacer()

            Button {
                Task { await runSend() }
            } label: {
                HStack(spacing: 8) {
                    if isSending {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(isSending ? "Sending…" : "Send")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(.tint, in: Capsule())
                .foregroundStyle(.white)
            }
            .disabled(isSending || ditheredImage == nil)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .padding(.top, 12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .topTrailing) {
            if sendError != nil {
                Text("Failed to send")
                    .font(.caption).foregroundStyle(.red)
                    .padding(.trailing, 16).padding(.top, -4)
            }
        }
    }

    private func roundButton(system: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: Circle())
        }
    }

    // MARK: - Edit panel

    // Compact intrinsic-height panel — safeAreaInset uses content's natural
    // size, so removing the Spacer makes the layout actually work and the
    // Send button is always visible.
    private var editPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Tune").font(.headline)
                Spacer()
                Button("Reset") {
                    sCurveStrength = 1.0
                    unsharpIntensity = 0.7
                    unsharpRadius = 1.0
                }
                .font(.callout)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Done editing")
            }

            sliderRow(label: "Contrast", system: "circle.lefthalf.filled",
                      value: $sCurveStrength, range: 0...2, percent: true)
            sliderRow(label: "Sharpness", system: "wand.and.rays",
                      value: $unsharpIntensity, range: 0...1.5, percent: true)
            sliderRow(label: "Radius", system: "scope",
                      value: $unsharpRadius, range: 0...3, percent: false)

            Button {
                Task { await runSend() }
            } label: {
                HStack(spacing: 8) {
                    if isSending {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(isSending ? "Sending…" : "Send")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSending || ditheredImage == nil)
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 12)
    }

    private func sliderRow(
        label: String, system: String,
        value: Binding<Float>, range: ClosedRange<Float>, percent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: system).foregroundStyle(.secondary).frame(width: 18)
                Text(label).font(.callout.weight(.medium))
                Spacer()
                Text(format(value.wrappedValue, percent: percent))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func format(_ v: Float, percent: Bool) -> String {
        percent ? String(format: "%.0f%%", v * 100) : String(format: "%.1f", v)
    }

    // MARK: - Toolbar buttons

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.5), in: Circle())
        }
        .accessibilityLabel("Back")
    }

    private var favButton: some View {
        let fav = currentEntry()?.favorite == true
        return Button {
            toggleFavorite()
        } label: {
            Image(systemName: fav ? "star.fill" : "star")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(fav ? .yellow : .white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.5), in: Circle())
        }
        .accessibilityLabel("Favorite")
    }

    // MARK: - Loading

    private func currentEntry() -> HistoryEntry? {
        guard let uuid = UUID(uuidString: currentItemID) else { return nil }
        return allEntries.first { $0.id == uuid }
    }

    // Eagerly populate pageImageCache for the current entry and its
    // immediate neighbours so a swipe from any direction lands on a page
    // that already has its source/dither bound. Without this, the new
    // page renders with PageImages() (empty) until disk I/O completes
    // and the displayed bytes can come from anywhere.
    private func preloadVisible() async {
        guard let idx = allEntries.firstIndex(where: { $0.id.uuidString == currentItemID }) else { return }
        let lo = max(0, idx - 1)
        let hi = min(allEntries.count - 1, idx + 1)
        let dt = displayType
        let entryIDs: [UUID] = (lo...hi).map { allEntries[$0].id }

        for id in entryIDs where pageImageCache[id] == nil {
            let sourceURL = try? EntryFileLayout.url(.source, for: id)
            let thumbURL = try? EntryFileLayout.url(.thumb, for: id)
            let ditherURL = try? EntryFileLayout.url(.dither, for: id)
            let images: PageImages = await Task.detached(priority: .userInitiated) {
                let raw = loadFreshUIImage(from: sourceURL)
                    ?? loadFreshUIImage(from: thumbURL)
                let cropped = raw.flatMap { cropToDisplayAspect($0, displayType: dt) }
                let dither = loadFreshUIImage(from: ditherURL)
                return PageImages(source: cropped, cachedDither: dither)
            }.value
            pageImageCache[id] = images
        }
        pruneCache(keepingAround: idx)
    }

    // Drop entries far from the active window so memory doesn't balloon as
    // the user navigates a long history.
    private func pruneCache(keepingAround idx: Int) {
        let keep = Set((max(0, idx - 2)...min(allEntries.count - 1, idx + 2)).map {
            allEntries[$0].id
        })
        pageImageCache = pageImageCache.filter { keep.contains($0.key) }
    }

    private func ensurePipeline() {
        if pipeline == nil {
            pipeline = LiveDitherPipeline(
                displayType: displayType,
                sCurveStrength: sCurveStrength,
                unsharpRadius: unsharpRadius,
                unsharpIntensity: unsharpIntensity,
                previewQuality: .quality
            )
        }
    }

    private func loadCurrent() async {
        loadTask?.cancel()
        currentSource = nil
        currentCropped = nil
        ditheredImage = nil
        sendError = nil
        // Invalidate "pipeline matches" until the new entry has actually
        // been ingested. While this is nil/stale, no page shows the live
        // overlay, so the boundary moment can't flash old data.
        pipelineEntryID = nil

        guard let entry = currentEntry() else { return }
        let itemID = entry.id.uuidString
        sCurveStrength = entry.sCurveStrength
        unsharpRadius = entry.unsharpRadius
        unsharpIntensity = entry.unsharpIntensity

        loadTask = Task {
            guard let ui = entry.loadImage(.source) ?? entry.loadImage(.thumb),
                  let cg = ui.cgImage
            else { return }
            // Crop only happens for the *hardware* path (pipeline + dither
            // for the 400x300 e-paper). Display preserves original aspect.
            let ci = CIImage(cgImage: cg)
            let displaySize = CGSize(width: displayType.width, height: displayType.height)
            let imagePortrait = ci.extent.height > ci.extent.width
            let displayPortrait = displaySize.height > displaySize.width
            let rotated = imagePortrait == displayPortrait ? ci : ci.oriented(.right)
            let cropped = centerCropToAspect(
                rotated,
                aspect: CGFloat(displayType.width) / CGFloat(displayType.height)
            )

            await MainActor.run {
                currentSource = ui
                currentCropped = cropped
                pipelineEntryID = itemID
                pipeline?.ingest(cropped)
            }
            await renderFinalDither(cropped)
        }
    }

    @MainActor
    private func renderFinalDither(_ cropped: CIImage) async {
        let dt = displayType
        let displaySize = CGSize(width: dt.width, height: dt.height)
        let scaled = cropped.scaled(contentMode: .scaleToFill, size: displaySize)
        let s = sCurveStrength, r = unsharpRadius, i = unsharpIntensity
        let palette = dt.colorPalette
        // Capture the entry id at render kickoff so we always associate the
        // output with the right entry — even if the user swiped to a new
        // page mid-render. Prevents the cross-contamination bug where one
        // entry's dither got saved to a different entry's .dither.png.
        let renderEntryID = pipelineEntryID
        let data = await scaled.atkinsonDithered(
            for: palette, sCurveStrength: s, unsharpRadius: r, unsharpIntensity: i
        )
        guard let image = try? EPaperNFCSwift.Image(data: data, for: dt) else { return }
        // Only update UI / cache if the user is still on the same entry the
        // render started for.
        if pipelineEntryID == renderEntryID {
            ditheredImage = image
        }
        if let id = renderEntryID, let uuid = UUID(uuidString: id) {
            await saveDitherCache(image: image, entryID: uuid)
        }
    }

    // Render the EPaperNFCSwift.Image to a UIImage and write into
    // .dither.png for the given entry — explicitly takes the entry id so
    // the destination is unambiguous regardless of current focus.
    @MainActor
    private func saveDitherCache(image: EPaperNFCSwift.Image, entryID: UUID) async {
        let ci = await image.renderCIImage()
        guard let cg = ci.cgImage ?? CIContext().createCGImage(ci, from: ci.extent) else { return }
        let ui = UIImage(cgImage: cg, scale: 1, orientation: .up)
        guard let pngData = ui.pngData(),
              let url = try? EntryFileLayout.url(.dither, for: entryID)
        else { return }
        try? pngData.write(to: url, options: .atomic)
    }

    // MARK: - Actions

    private func toggleFavorite() {
        guard let entry = currentEntry() else { return }
        historyStore.setFavorite(entry, !entry.favorite)
    }

    private func runSend() async {
        guard let image = ditheredImage else { return }
        guard !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }

        var thrownError: (any Error)?
        do {
            try await ePaperNFCService.sendImage(image) {
                .message(String(localized: "Hold your device near the e-Paper."))
            } onSendImageProgress: { progress in
                .message(String(localized: "Sending… \(progress, format: .percent.precision(.fractionLength(0)))"))
            } onWaitForRefresh: { isCompleted in
                .message(isCompleted ? String(localized: "Completed.") : String(localized: "Updating…"))
            } onError: { error in
                logger.error(error)
                Task { @MainActor in sendError = error }
                return .message(String(localized: "Failed."))
            } onPhase: { _ in }
        } catch {
            thrownError = error
            logger.error(error)
        }
        if thrownError == nil && sendError == nil {
            await persistSendSuccess(image: image)
        }
    }

    @MainActor
    private func persistSendSuccess(image: EPaperNFCSwift.Image) async {
        guard let entry = currentEntry() else { return }
        let settings = RenderSettings(
            sCurveStrength: sCurveStrength,
            unsharpRadius: unsharpRadius,
            unsharpIntensity: unsharpIntensity
        )
        let ditherUI: UIImage? = await renderUIImage(from: image)
        historyStore.updateOnSendSuccess(
            entry,
            renderSettings: settings,
            ditherImage: ditherUI,
            sourceImage: currentSource
        )
    }

    @concurrent
    private func renderUIImage(from image: EPaperNFCSwift.Image) async -> UIImage? {
        let ci = await image.renderCIImage()
        if let cg = ci.cgImage { return UIImage(cgImage: cg, scale: 1, orientation: .up) }
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}

// MARK: - Per-page rendering

// Pure data carrier passed into the (stateless) DetailPage. Owned by the
// parent's pageImageCache keyed by entry.id.
struct PageImages: Equatable {
    var source: UIImage?
    var cachedDither: UIImage?
}

@MainActor
private struct DetailPage: View {
    let images: PageImages
    let isCurrent: Bool
    // Live overlay only matters in Tune mode (real-time slider feedback).
    // Outside tune, the cached dither is the source of truth — and showing
    // the live overlay during browsing/swipe leaks the previous entry's
    // pipeline output onto the freshly-focused page (the bug we chased).
    let isEditing: Bool
    let ditherPreview: CIImage?
    let showSourceOnly: Bool

    var body: some View {
        ZStack {
            if let source = images.source {
                Image(uiImage: source)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.black
            }

            if !showSourceOnly, let dither = images.cachedDither {
                Image(uiImage: dither)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            }

            if isEditing && isCurrent && !showSourceOnly, let ditherPreview {
                MetalCIPreviewView(image: ditherPreview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helpers

private struct TuneInputs: Equatable, Hashable {
    var s: Float
    var r: Float
    var i: Float
}

