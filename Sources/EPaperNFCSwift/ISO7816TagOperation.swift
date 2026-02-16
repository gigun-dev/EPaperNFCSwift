//
//  ISO7816TagOperaion.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/19/26.
//

import CoreNFC
import Foundation

protocol ISO7816TagOperationContext: Sendable {
    func updateAlertMessage(_ message: String) async -> Void
}

enum ISO7816TagOperationResult<Result: Sendable> {
    case completed(Result)
    case restartPolling
}

protocol ISO7816TagOperation: Sendable {
    associatedtype Result: Sendable

    func perform(
        on tag: UncheckedSendable<NFCISO7816Tag>,
        context: ISO7816TagOperationContext
    ) async throws -> ISO7816TagOperationResult<Result>
}
