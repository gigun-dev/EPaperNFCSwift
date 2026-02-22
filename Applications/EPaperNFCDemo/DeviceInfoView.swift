//
//  DeviceInfoView.swift
//  EPaperNFCDemo
//
//  Created by Yoshimasa Niwa on 2/20/26.
//

import EPaperNFCSwift
import Foundation
import SwiftUI

private extension DisplayType.ColorPalette {
    var localizedName: LocalizedStringKey {
        switch self {
        case .blackAndWhite:
            "2-Color"
        case .blackWhiteYellowRed:
            "4-Color"
        }
    }
}

struct DeviceInfoView: View {
    var deviceInfo: DeviceInfo

    var body: some View {
        LabeledContent {
            Text(String(format: "%08X", deviceInfo.id))
                .monospaced()
        } label: {
            Text("Identifier")
        }

        LabeledContent {
            Text(deviceInfo.name)
                .monospaced()
        } label: {
            Text("Name")
        }

        LabeledContent {
            Text(deviceInfo.displayType.colorPalette.localizedName)
        } label: {
            Text("Colors")
        }

        LabeledContent {
            Text("\(deviceInfo.displayType.width) px")
        } label: {
            Text("Width")
        }

        LabeledContent {
            Text("\(deviceInfo.displayType.height) px")
        } label: {
            Text("Height")
        }
    }
}

#Preview {
    Form {
        Section("Preview") {
            DeviceInfoView(deviceInfo: .init(
                id: 0x12345678,
                name: "Preview",
                displayType: .fourPointTwoInchBlackAndWhite
            ))
        }
    }
}
