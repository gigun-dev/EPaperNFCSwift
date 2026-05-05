//
//  SendImageOperation.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/19/26.
//

import CoreNFC
import Foundation

public typealias OnSessionSendImageProgress = @Sendable (Float) async -> ISO7816TagSessionUpdate
public typealias OnSessionWaitForRefresh = @Sendable (Bool) async -> ISO7816TagSessionUpdate

// Lifecycle events for the send-image operation. Used for diagnostics so a
// failure can be traced back to the phase and chunk where it happened.
public enum SendImagePhase: Sendable, Hashable {
    case auth
    case sendChunkStarted(index: Int, count: Int)
    case sendChunkCompleted(index: Int, count: Int)
    case refreshStarted
    case refreshCompleted
}

public typealias OnSessionSendImagePhase = @Sendable (SendImagePhase) async -> Void

final actor SendImageOperation: ISO7816TagOperation {
    typealias Result = Void

    let image: Image
    let onSendImageProgress: OnSessionSendImageProgress?
    let onWaitForRefresh: OnSessionWaitForRefresh?
    let onPhase: OnSessionSendImagePhase?

    init(
        image: Image,
        onSendImageProgress: OnSessionSendImageProgress?,
        onWaitForRefresh: OnSessionWaitForRefresh?,
        onPhase: OnSessionSendImagePhase?
    ) {
        self.image = image
        self.onSendImageProgress = onSendImageProgress
        self.onWaitForRefresh = onWaitForRefresh
        self.onPhase = onPhase
    }

    func perform(
        on tag: UncheckedSendable<NFCISO7816Tag>,
        context: ISO7816TagOperationContext
    ) async throws -> ISO7816TagOperationResult<Void> {
        await onPhase?(.auth)
        try await tag.value.sendAPDUCommand(AuthAPDUCommand())

        if let update = await onSendImageProgress?(0.0), let message = update.message {
            await context.updateAlertMessage(message)
        }

        let commands = SendImageAPDUCommand.sendImageAPDUCommands(for: image)
        for (index, command) in commands.enumerated() {
            await onPhase?(.sendChunkStarted(index: index, count: commands.count))
            try await tag.value.sendAPDUCommand(command)
            await onPhase?(.sendChunkCompleted(index: index, count: commands.count))

            let progress = Float(index + 1) / Float(commands.count)
            if let update = await onSendImageProgress?(progress), let message = update.message {
                await context.updateAlertMessage(message)
            }
        }

        if let update = await onWaitForRefresh?(false), let message = update.message {
            await context.updateAlertMessage(message)
        }

        // Refresh takes longer than 20 seconds, especially for 4-color displays.
        // Core NFC normally invalidates the tag connection after 20 seconds, but
        // a blocking APDU lets the card extend the connection via WTX frames
        // until refresh completes.
        await onPhase?(.refreshStarted)
        try await tag.value.sendAPDUCommand(RefreshAPDUCommand(waitForRefresh: true))
        await onPhase?(.refreshCompleted)

        if let update = await onWaitForRefresh?(true), let message = update.message {
            await context.updateAlertMessage(message)
        }

        return .completed(())
    }
}

public func sendImage(
    _ image: Image,
    onBegin: OnSessionBegin? = nil,
    onSendImageProgress: OnSessionSendImageProgress? = nil,
    onWaitForRefresh: OnSessionWaitForRefresh? = nil,
    onError: OnSessionError? = nil,
    onPhase: OnSessionSendImagePhase? = nil
) async throws {
    try await performOperation(
        SendImageOperation(
            image: image,
            onSendImageProgress: onSendImageProgress,
            onWaitForRefresh: onWaitForRefresh,
            onPhase: onPhase
        ),
        onBegin: onBegin,
        onError: onError
    )
}
