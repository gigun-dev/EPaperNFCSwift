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
                    do {
                        guard !isLoading else {
                            return
                        }

                        isLoading = true
                        defer {
                            isLoading = false
                        }

                        lastError = nil

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
                        }
                    } catch {
                        logger.error(error)
                    }
                }
            } label: {
                Text("Send")
            }
        }

        if lastError != nil{
            Text("Failed to send.")
                .foregroundStyle(.red)
        }
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
