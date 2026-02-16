//
//  UncheckedSendable.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/19/26.
//

// NOTE: `NFCTagReaderSession` and `NFCTag` API has internal lock and
// designed to be thread-safe in general.
// However, it's currently `nonisolated` thus wraps them in the box.

final class UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
