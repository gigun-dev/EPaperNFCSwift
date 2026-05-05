//
//  DeviceSetupView.swift
//  EPaperNFCDemo
//

import EPaperNFCSwift
import OSLog
import SwiftUI

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "DeviceSetupView"
)

private extension DisplayType {
    var localizedName: LocalizedStringKey {
        switch self {
        case .twoPointNineInchBlackAndWhite: "2.9-inch 2-Color"
        case .twoPointNineInchBlackWhiteYellowRed: "2.9-inch 4-Color"
        case .fourPointTwoInchBlackAndWhite: "4.2-inch 2-Color"
        case .fourPointTwoInchBlackWhiteYellowRed: "4.2-inch 4-Color"
        default: "Display"
        }
    }
}

// Hero landing screen shown when no display has been detected or selected
// yet. The primary action is "Detect" which fires the NFC reader; manual
// model selection is available as a secondary option for cases where the
// device cannot be reached physically.
struct DeviceSetupView: View {
    @Environment(AnyEPaperNFCService.self)
    private var ePaperNFCService

    @Binding
    var displayType: DisplayType?

    @State
    private var isDetecting: Bool = false
    @State
    private var lastError: (any Error)?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "wave.3.right.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text("Pair your e-Paper")
                    .font(.title2.weight(.semibold))
                Text("Hold your iPhone near the e-Paper to detect it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            VStack(spacing: 12) {
                Button {
                    Task { await detect() }
                } label: {
                    HStack(spacing: 8) {
                        if isDetecting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(isDetecting ? "Detecting…" : "Detect e-Paper")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isDetecting)

                if let lastError {
                    Text(errorMessage(lastError))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)

            Menu {
                ForEach(DisplayType.allDisplayTypes) { dt in
                    Button(action: { displayType = dt }) {
                        Text(dt.localizedName)
                    }
                }
            } label: {
                Text("Pick model manually")
                    .font(.callout)
            }
            .disabled(isDetecting)

            Spacer()
        }
    }

    private func detect() async {
        guard !isDetecting else { return }
        isDetecting = true
        defer { isDetecting = false }
        lastError = nil
        do {
            let info = try await ePaperNFCService.deviceInfo {
                return .message(String(localized: "Hold your iPhone near the e-Paper."))
            } onError: { error in
                logger.error(error)
                Task { @MainActor in lastError = error }
                return .message(String(localized: "Failed."))
            }
            displayType = info.displayType
        } catch {
            logger.error(error)
        }
    }

    private func errorMessage(_ error: any Error) -> String {
        let ns = error as NSError
        if !ns.localizedDescription.isEmpty {
            return ns.localizedDescription
        }
        return "Detection failed."
    }
}

#Preview {
    @Previewable
    @State
    var displayType: DisplayType?

    DeviceSetupView(displayType: $displayType)
        .previewEnvironment()
}
