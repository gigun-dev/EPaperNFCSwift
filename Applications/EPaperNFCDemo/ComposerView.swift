//
//  ComposerView.swift
//  EPaperNFCDemo
//

import CoreImage
import EPaperNFCSwift
import OSLog
import SwiftUI
import UIKit

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "ComposerView"
)

// Post-capture / post-pick editor. Receives a source CIImage already cropped
// and oriented for the target display, re-dithers on slider changes, and
// presents a single big Send action.
struct ComposerView: View {
    let source: CIImage
    let displayType: DisplayType
    let entrySource: EntrySource
    // When non-nil, send-success updates the existing entry instead of
    // creating a new one. Set when re-opening from history.
    let existingEntryID: UUID?

    @Binding var sCurveStrength: Float
    @Binding var unsharpRadius: Float
    @Binding var unsharpIntensity: Float

    @Environment(\.dismiss) private var dismiss
    @Environment(AnyEPaperNFCService.self) private var ePaperNFCService
    @Environment(HistoryStore.self) private var historyStore

    @State private var preview: UIImage?
    @State private var ditheredImage: EPaperNFCSwift.Image?
    @State private var renderTask: Task<Void, Never>?
    @State private var isSending: Bool = false
    @State private var sendError: (any Error)?
    // Auto-created draft entry ID when this view is opened with a fresh
    // source (existingEntryID == nil). Lets the source image persist in
    // My Photos even if the user never hits Send.
    @State private var draftEntryID: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewArea

                controls
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                sendArea
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Send to e-Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sCurveStrength = 1.0
                        unsharpIntensity = 0.7
                        unsharpRadius = 1.0
                    } label: {
                        Label("Reset", systemImage: "arrow.uturn.backward")
                    }
                }
            }
        }
        .task {
            kickRender()
            await ensureDraftEntry()
        }
        .onChange(of: TuneInputs(
            sCurveStrength: sCurveStrength,
            unsharpRadius: unsharpRadius,
            unsharpIntensity: unsharpIntensity
        )) { _, _ in
            kickRender()
        }
        .onDisappear {
            renderTask?.cancel()
        }
    }

    private var previewArea: some View {
        ZStack(alignment: .topTrailing) {
            Color(.secondarySystemBackground)
                .ignoresSafeArea(edges: .top)

            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .padding(20)
            } else {
                ProgressView()
            }

            if renderTask != nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            sliderRow(
                label: "Contrast",
                systemImage: "circle.lefthalf.filled",
                value: $sCurveStrength,
                range: 0...2,
                displayPercent: true
            )
            sliderRow(
                label: "Sharpness",
                systemImage: "wand.and.rays",
                value: $unsharpIntensity,
                range: 0...1.5,
                displayPercent: true
            )
            sliderRow(
                label: "Sharpness radius",
                systemImage: "scope",
                value: $unsharpRadius,
                range: 0...3,
                displayPercent: false
            )
        }
    }

    private var sendArea: some View {
        VStack(spacing: 8) {
            Button {
                guard let ditheredImage else { return }
                Task { await runSend(ditheredImage) }
            } label: {
                HStack(spacing: 8) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(isSending ? "Sending…" : "Send")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(ditheredImage == nil || isSending)

            if sendError != nil {
                Text("Failed to send.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func sliderRow(
        label: String,
        systemImage: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        displayPercent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(label)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(formattedValue(value.wrappedValue, percent: displayPercent))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func formattedValue(_ value: Float, percent: Bool) -> String {
        if percent {
            return String(format: "%.0f%%", value * 100)
        }
        return String(format: "%.1f", value)
    }

    private func kickRender() {
        renderTask?.cancel()
        let s = sCurveStrength
        let r = unsharpRadius
        let i = unsharpIntensity
        let palette = displayType.colorPalette
        let dt = displayType
        let displaySize = CGSize(width: dt.width, height: dt.height)
        let scaled = source.scaled(
            contentMode: .scaleToFill,
            size: displaySize
        )
        renderTask = Task {
            let data = await scaled.atkinsonDithered(
                for: palette,
                sCurveStrength: s,
                unsharpRadius: r,
                unsharpIntensity: i
            )
            if Task.isCancelled { return }
            do {
                let image = try EPaperNFCSwift.Image(data: data, for: dt)
                let ci = await image.renderCIImage()
                let ui = await Self.renderUIImage(from: ci)
                if Task.isCancelled { return }
                ditheredImage = image
                preview = ui
                renderTask = nil
            } catch {
                logger.error(error)
                renderTask = nil
            }
        }
    }

    @concurrent
    private static func renderUIImage(from ci: CIImage) async -> UIImage? {
        if let cg = ci.cgImage {
            return UIImage(cgImage: cg)
        }
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    private func runSend(_ image: EPaperNFCSwift.Image) async {
        guard !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }

        let recorder = SendLogRecorder(
            displayTypeID: String(describing: image.displayType),
            dataByteCount: image.data.count,
            paletteHistogram: paletteHistogram(for: image)
        )

        var thrownError: (any Error)?
        do {
            try await ePaperNFCService.sendImage(image) {
                return .message(String(localized: "Hold your device near the e-Paper."))
            } onSendImageProgress: { progress in
                return .message(String(localized: "Sending… \(progress, format: .percent.precision(.fractionLength(0)))"))
            } onWaitForRefresh: { isCompleted in
                return .message(isCompleted ? String(localized: "Completed.") : String(localized: "Updating…"))
            } onError: { error in
                logger.error(error)
                Task { @MainActor in
                    sendError = error
                }
                return .message(String(localized: "Failed."))
            } onPhase: { phase in
                recorder.record(phase)
            }
        } catch {
            thrownError = error
            logger.error(error)
        }

        let entry = recorder.finalize(error: thrownError)
        SendLogStore.shared.append(entry)

        if thrownError == nil && sendError == nil {
            await persistHistory(image: image)
            dismiss()
        }
    }

    @MainActor
    private func persistHistory(image: EPaperNFCSwift.Image) async {
        let ditherUI: UIImage? = preview
        let sourceUI: UIImage? = await Self.renderUIImage(from: source)
        let settings = RenderSettings(
            sCurveStrength: sCurveStrength,
            unsharpRadius: unsharpRadius,
            unsharpIntensity: unsharpIntensity
        )
        // Effective entry to update: explicit existing entry (re-edit from
        // history) takes precedence; otherwise the auto-draft we created on
        // first appear gets promoted to .sent.
        if let id = existingEntryID ?? draftEntryID,
           let existing = historyStore.entry(id: id) {
            historyStore.updateOnSendSuccess(
                existing,
                renderSettings: settings,
                ditherImage: ditherUI,
                sourceImage: sourceUI
            )
        } else {
            historyStore.record(
                source: entrySource,
                status: .sent,
                displayType: image.displayType,
                renderSettings: settings,
                ditherImage: ditherUI,
                sourceImage: sourceUI,
                sentAt: Date()
            )
        }
    }

    @MainActor
    private func ensureDraftEntry() async {
        // Only create a draft when the Composer was opened on a fresh source.
        // History-restore flows (existingEntryID set) already have an entry.
        guard existingEntryID == nil, draftEntryID == nil else { return }
        let sourceUI = await Self.renderUIImage(from: source)
        let settings = RenderSettings(
            sCurveStrength: sCurveStrength,
            unsharpRadius: unsharpRadius,
            unsharpIntensity: unsharpIntensity
        )
        let entry = historyStore.record(
            source: entrySource,
            status: .draft,
            displayType: displayType,
            renderSettings: settings,
            ditherImage: nil,
            sourceImage: sourceUI
        )
        draftEntryID = entry.id
        // Auto-render initial dither in the background so the just-captured
        // entry shows with the filter applied next time the user lands in
        // the gallery — without waiting for an explicit send.
        let entryID = entry.id
        let dt = displayType
        Task.detached(priority: .utility) {
            await renderInitialDitherIfMissing(entryID: entryID, displayType: dt, settings: settings)
        }
    }
}

private func paletteHistogram(for image: EPaperNFCSwift.Image) -> [PaletteBin] {
    let labels = paletteLabels(for: image.displayType.colorPalette)
    var counts = [Int](repeating: 0, count: labels.count)
    for byte in image.data {
        let index = Int(byte)
        if index < counts.count {
            counts[index] += 1
        }
    }
    return zip(labels, counts).map { PaletteBin(label: $0.0, count: $0.1) }
}

private func paletteLabels(for colorPalette: DisplayType.ColorPalette) -> [String] {
    switch colorPalette {
    case .blackAndWhite: ["Black", "White"]
    case .blackWhiteYellowRed: ["Black", "White", "Yellow", "Red"]
    }
}

private struct TuneInputs: Equatable, Hashable {
    var sCurveStrength: Float
    var unsharpRadius: Float
    var unsharpIntensity: Float
}
