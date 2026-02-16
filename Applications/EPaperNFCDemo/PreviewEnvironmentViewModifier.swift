//
//  PreviewEnvironmentViewModifier.swift
//  EPaperNFCDemo
//
//  Created by Yoshimasa Niwa on 2/20/26.
//

import Foundation
import SwiftUI

struct PreviewEnvironmentViewModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(PreviewEPaperNFCService().eraseToAnyEPaperNFCService())
    }
}

extension View {
    func previewEnvironment() -> some View {
        modifier(PreviewEnvironmentViewModifier())
    }
}
