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
    @State
    private var displayType: DisplayType?
    @State
    private var sCurveStrength: Float = 1.0
    @State
    private var unsharpRadius: Float = 1.0
    @State
    private var unsharpIntensity: Float = 0.7

    var body: some View {
        Group {
            if displayType == nil {
                NavigationStack {
                    DeviceSetupView(displayType: $displayType)
                }
            } else {
                RootTabView(
                    displayType: $displayType,
                    sCurveStrength: $sCurveStrength,
                    unsharpRadius: $unsharpRadius,
                    unsharpIntensity: $unsharpIntensity
                )
            }
        }
    }
}

#Preview {
    MainView()
        .previewEnvironment()
}
