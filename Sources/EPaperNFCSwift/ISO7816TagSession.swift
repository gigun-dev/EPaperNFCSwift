//
//  ISO7816TagSession.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/16/26.
//

import CoreNFC
import Dispatch
import Foundation

public struct ISO7816TagSessionUpdate: Sendable {
    var message: String?

    public init(
        message: String? = nil
    ) {
        self.message = message
    }
}

extension ISO7816TagSessionUpdate {
    public static let noMessage = Self()

    public static func message(_ message: String) -> Self {
        .init(message: message)
    }
}

public typealias OnSessionBegin = @Sendable () async -> ISO7816TagSessionUpdate
public typealias OnSessionError = @Sendable (any Error) async -> ISO7816TagSessionUpdate

// TODO: Rename errors
public enum ISO7816TagSessionError: Error {
    case internalInconsistency
    case readingUnavailable
    case failedToStartSession
    case noTagDetected
    case moreThanOneTagDetected
    case notISO7816TagDetected
    case differentTagDetected
    case tagDetectedWhileWaitingForRefresh
    case failedToWaitForRefresh
}

final actor ISO7816TagSession<Operation: ISO7816TagOperation>: NSObject {
    private let operation: Operation
    private let onBegin: OnSessionBegin?
    private let onError: OnSessionError?

    private let continuation: CheckedContinuation<Operation.Result, any Error>

    init(
        operation: Operation,
        onBegin: OnSessionBegin? = nil,
        onError: OnSessionError? = nil,
        continuation: CheckedContinuation<Operation.Result, any Error>
    ) {
        self.operation = operation
        self.onBegin = onBegin
        self.onError = onError
        self.continuation = continuation
    }

    private var session: UncheckedSendable<NFCTagReaderSession>?
    private var isSessionInvalidatedForCompletion: Bool = false

    private var tagIdentifier: Data?

    func begin() async {
        guard session == nil else {
            continuation.resume(throwing: ISO7816TagSessionError.internalInconsistency)
            return
        }

        guard NFCTagReaderSession.readingAvailable else {
            continuation.resume(throwing: ISO7816TagSessionError.readingUnavailable)
            return
        }

        guard let session = NFCTagReaderSession(
            pollingOption: [.iso14443],
            // `NFCTagReaderSession` has weak reference to delegate.
            delegate: self
        ) else {
            continuation.resume(throwing: ISO7816TagSessionError.failedToStartSession)
            return
        }

        self.session = UncheckedSendable(session)

        if let update = await onBegin?(), let message = update.message {
            session.alertMessage = message
        }
        session.begin()
    }

    private func didDetectTags(_ tags: [UncheckedSendable<NFCTag>]) async {
        guard let session else {
            // Must not reach here.
            _ = await onError?(ISO7816TagSessionError.internalInconsistency)
            continuation.resume(throwing: ISO7816TagSessionError.internalInconsistency)
            return
        }

        do {
            guard let tag = tags.first else {
                throw ISO7816TagSessionError.noTagDetected
            }

            if tags.count > 1 {
                throw ISO7816TagSessionError.moreThanOneTagDetected
            }

            guard case let .iso7816(iso7816tag) = tag.value else {
                throw ISO7816TagSessionError.notISO7816TagDetected
            }

            // Validate tag identifier on restart.
            if let tagIdentifier {
                guard iso7816tag.identifier == tagIdentifier else {
                    throw ISO7816TagSessionError.differentTagDetected
                }
            } else {
                tagIdentifier = iso7816tag.identifier
            }

            try await session.value.connect(to: .iso7816(iso7816tag))

            let result = try await operation.perform(
                on: UncheckedSendable<NFCISO7816Tag>(iso7816tag),
                context: self
            )

            switch result {
            case .completed(let value):
                // See `didInvalidateWithError(_:)` for this session `invalidate()`.
                isSessionInvalidatedForCompletion = true
                session.value.invalidate()
                continuation.resume(returning: value)

            case .restartPolling:
                session.value.restartPolling()
            }
        } catch {
            let update = await onError?(error)

            switch error {
            case ISO7816TagSessionError.moreThanOneTagDetected:
                if let update, let message = update.message {
                    session.value.alertMessage = message
                }
                session.value.restartPolling()
            default:
                // Any errors except when we found multiple tags invalidate session,
                // which calls `continuation.resume(throwing:)` eventually via delegate.
                if let update, let message = update.message {
                    session.value.invalidate(errorMessage: message)
                } else {
                    session.value.invalidate()
                }
            }
        }
    }

    private func didInvalidateWithError(_ error: any Error) {
        if case NFCReaderError.readerSessionInvalidationErrorUserCanceled = error,
           isSessionInvalidatedForCompletion
        {
            // `continuation` has been resumed already, ignore this case.
            // See `didDetectTags(_:)` as well.
            return
        }

        continuation.resume(throwing: error)
    }
}

extension ISO7816TagSession: ISO7816TagOperationContext {
    func updateAlertMessage(_ message: String) {
        guard let session else {
            return
        }

        session.value.alertMessage = message
    }
}

extension ISO7816TagSession: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        // Called on `session.sessionQueue`.
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        // Called on `session.sessionQueue`.

        let tags = tags.map { tag in
            UncheckedSendable(tag)
        }

        Task {
            await didDetectTags(tags)
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: any Error) {
        // Called on `session.sessionQueue`.
        Task {
            await didInvalidateWithError(error)
        }
    }
}

func performOperation<Operation: ISO7816TagOperation>(
    _ operation: Operation,
    onBegin: OnSessionBegin? = nil,
    onError: OnSessionError? = nil
) async throws -> Operation.Result {
    nonisolated(unsafe) var tagSession: ISO7816TagSession<Operation>?

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Operation.Result, any Error>) in
        let session = ISO7816TagSession(
            operation: operation,
            onBegin: onBegin,
            onError: onError,
            continuation: continuation
        )
        // Extends lifetime of the session until `performOperation(_:onBegin:onError:)` ends.
        tagSession = session

        Task {
            await session.begin()
        }
    }
}
