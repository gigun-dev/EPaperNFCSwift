//
//  DetectDeviceInfoView.swift
//  EPaperNFCDemo
//
//  Created by Yoshimasa Niwa on 2/20/26.
//

import EPaperNFCSwift
import Foundation
import OSLog
import SwiftUI

private nonisolated let logger = Logger(
    subsystem: "EPaperNFCDemo",
    category: "DetectDeviceInfoView"
)

struct DetectDeviceInfoView: View {
    @Environment(AnyEPaperNFCService.self)
    private var ePaperNFCService

    @State
    private var lastError: (any Error)?
    @State
    private var isLoading: Bool = false

    @Binding
    var deviceInfo: DeviceInfo?

    var body: some View {
        if isLoading {
            LabeledContent {
                ProgressView()
                    .controlSize(.small)
                    .id(NSObject())
            } label: {
                Text("Detecting…")
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
                        deviceInfo = nil

                        deviceInfo = try await ePaperNFCService.deviceInfo {
                            return .message(String(localized: "Hold your device near the e-Paper."))
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
                Text("Detect")
            }
        }

        if lastError != nil{
            Text("Failed to detect.")
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    @Previewable
    @State
    var deviceInfo: DeviceInfo? = nil

    Form {
        Section("Preview") {
            DetectDeviceInfoView(deviceInfo: $deviceInfo)
                .previewEnvironment()
        }
    }
}
