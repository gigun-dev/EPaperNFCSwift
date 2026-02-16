//
//  DeviceInfoOperation.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/19/26.
//

import CoreNFC
import Foundation

final actor DeviceInfoOperation: ISO7816TagOperation {
    typealias Result = DeviceInfo

    func perform(
        on tag: UncheckedSendable<NFCISO7816Tag>,
        context: ISO7816TagOperationContext
    ) async throws -> ISO7816TagOperationResult<Result> {
        let response = try await tag.value.sendAPDUCommand(DeviceInfoAPDUCommand())

        return .completed(response)
    }
}

public func deviceInfo(
    onBegin: OnSessionBegin? = nil,
    onError: OnSessionError? = nil
) async throws -> DeviceInfo {
    try await performOperation(
        DeviceInfoOperation(),
        onBegin: onBegin,
        onError: onError
    )
}
