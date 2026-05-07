//
//  MainApp.swift
//  EPaperNFCDemo
//
//  Created by Yoshimasa Niwa on 2/16/26.
//

import Foundation
import SwiftData
import SwiftUI

@main
struct MainApp: App {
    // One-shot migration flags. Each name encodes a distinct historical
    // cleanup the app needs to do exactly once on a given device.
    @AppStorage("didWipeDitherCacheV3") private var didWipeDitherCache: Bool = false
    @AppStorage("didCleanupDuplicatesV1") private var didCleanupDuplicates: Bool = false

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(EPaperNFCService().eraseToAnyEPaperNFCService())
                .environment(SendLogStore.shared)
                .environment(HistoryStore.shared)
                .environment(PhotoLibraryAccess.shared)
                .environment(OrientationObserver())
                .modelContainer(HistoryStore.shared.container)
                .task {
                    if !didCleanupDuplicates {
                        HistoryStore.shared.cleanupDuplicates()
                        didCleanupDuplicates = true
                    }
                    if !didWipeDitherCache {
                        HistoryStore.shared.clearAllDitherCache()
                        didWipeDitherCache = true
                    }
                }
        }
    }
}
