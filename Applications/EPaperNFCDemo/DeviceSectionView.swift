//
//  DeviceSectionView.swift
//  EPaperNFCDemo
//
//  Created by Yoshimasa Niwa on 2/20/26.
//

import EPaperNFCSwift
import Foundation
import SwiftUI

private extension DisplayType {
    var localizedName: LocalizedStringKey {
        switch self {
        case .twoPointNineInchBlackAndWhite:
            "2.9-inch 2-Color"
        case .twoPointNineInchBlackWhiteYellowRed:
            "2.9-inch 4-Color"
        case .fourPointTwoInchBlackAndWhite:
            "4.2-inch 2-Color"
        case .fourPointTwoInchBlackWhiteYellowRed:
            "4.2-inch 4-Color"
        default:
            "Display"
        }
    }
}

struct DeviceSectionView: View {
    @State
    private var deviceInfo: DeviceInfo?

    @Binding
    var displayType: DisplayType?

    var body: some View {
        Group {
            Picker(selection: $displayType) {
                ForEach(DisplayType.allDisplayTypes) { displayType in
                    Text(displayType.localizedName)
                        .tag(displayType as DisplayType?)
                }
                if let displayType, !DisplayType.allDisplayTypes.contains(displayType) {
                    Text("Detected")
                        .tag(displayType as DisplayType?)
                }
                Text("Detect")
                    .tag(nil as DisplayType?)
            } label: {
                Text("Display")
            }

            if displayType == nil {
                DetectDeviceInfoView(deviceInfo: $deviceInfo)
            }

            if let deviceInfo {
                DeviceInfoView(deviceInfo: deviceInfo)
            }
        }
        .onChange(of: displayType) { _, newValue in
            if let deviceInfo, deviceInfo.displayType != newValue {
                self.deviceInfo = nil
            }
        }
        .onChange(of: deviceInfo) { _, newValue in
            if let newValue {
                displayType = newValue.displayType
            }
        }
    }
}

#Preview {
    @Previewable
    @State
    var displayType: DisplayType? = nil

    Form {
        Section("Preview") {
            DeviceSectionView(displayType: $displayType)
                .previewEnvironment()
        }
    }
}
