//
//  MainView.swift
//  EPaperNFCDemo
//
//  Created by Yoshimasa Niwa on 2/16/26.
//

import EPaperNFCSwift
import Foundation
import SwiftUI

struct MainView: View {
    // Persist the last paired (or manually selected) display so the user
    // doesn't have to re-pair on every launch. Encoded as the raw key
    // (width|height|palette|orientation); decoded back via DisplayTypeKey.
    @AppStorage("lastDisplayTypeKey")
    private var displayTypeKeyRaw: String = ""

    @State
    private var sCurveStrength: Float = 1.0
    @State
    private var unsharpRadius: Float = 1.0
    @State
    private var unsharpIntensity: Float = 0.7

    private var displayType: Binding<DisplayType?> {
        Binding(
            get: { resolveDisplayType() },
            set: { newValue in
                displayTypeKeyRaw = newValue.map { encode($0) } ?? ""
            }
        )
    }

    var body: some View {
        // No pairing gate at launch — always go straight into the tab UI.
        // First-run defaults to the most common 4.2-inch 4-Color model;
        // the user can re-detect or change via the (i) toolbar button on
        // either tab. Pairing physically happens at NFC tap during send.
        RootTabView(
            displayType: displayType,
            sCurveStrength: $sCurveStrength,
            unsharpRadius: $unsharpRadius,
            unsharpIntensity: $unsharpIntensity
        )
    }

    private func resolveDisplayType() -> DisplayType {
        if !displayTypeKeyRaw.isEmpty,
           let decoded = decode(displayTypeKeyRaw)
        {
            return decoded
        }
        return .fourPointTwoInchBlackWhiteYellowRed
    }

    private func encode(_ dt: DisplayType) -> String {
        let key = DisplayTypeKey.from(dt)
        return [
            String(key.width),
            String(key.height),
            key.paletteRaw,
            key.orientationRaw
        ].joined(separator: "|")
    }

    private func decode(_ raw: String) -> DisplayType? {
        let parts = raw.split(separator: "|").map(String.init)
        guard parts.count == 4,
              let w = Int(parts[0]),
              let h = Int(parts[1])
        else { return nil }
        let key = DisplayTypeKey(
            width: w,
            height: h,
            paletteRaw: parts[2],
            orientationRaw: parts[3]
        )
        return key.resolve()
    }
}

#Preview {
    MainView()
        .previewEnvironment()
}
