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
    private var image: EPaperNFCSwift.Image?

    var body: some View {
        NavigationStack {
            Form {
                Section("e-Paper") {
                    DeviceSectionView(displayType: $displayType)
                }

                if let displayType {
                    Section("Image") {
                        ImageSectionView(displayType: displayType, image: $image)
                    }

                    if let image {
                        Section {
                            SendImageView(image: image)
                        }
                    }
                }
            }
            .navigationTitle("ePaper NFC Demo")
        }
    }
}

#Preview {
    MainView()
        .previewEnvironment()
}
