//
//  MainApp.swift
//  EPaperNFCDemo
//
//  Created by Yoshimasa Niwa on 2/16/26.
//

import Foundation
import SwiftUI

@main
struct MainApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(EPaperNFCService().eraseToAnyEPaperNFCService())
        }
    }
}
