//
//  SendImageView.swift
//  EPaperNFCDemo
//
//  Created by Yoshimasa Niwa on 2/20/26.
//

import EPaperNFCSwift
import OSLog
import SwiftUI

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "SendImageView"
)

struct SendImageView: View {
    @Environment(AnyEPaperNFCService.self)
    private var ePaperNFCService

    @State
    private var lastError: (any Error)?
    @State
    private var isLoading: Bool = false

    var image: EPaperNFCSwift.Image

    var body: some View {
        if isLoading {
            LabeledContent {
                ProgressView()
                    .controlSize(.small)
                    .id(NSObject())
            } label: {
                Text("Sending…")
            }
        } else {
            Button {
                Task {
                    await runSend()
                }
            } label: {
                Text("Send")
            }
        }

        if lastError != nil {
            Text("Failed to send.")
                .foregroundStyle(.red)
        }
    }

    private func runSend() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        lastError = nil

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
                    lastError = error
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

#Preview {
    Form {
        Section("Preview") {
            SendImageView(image: Image.demoImage(for: .twoPointNineInchBlackWhiteYellowRed))
                .previewEnvironment()
        }
    }
}
