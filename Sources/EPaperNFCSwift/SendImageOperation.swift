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

final actor SendImageOperation: ISO7816TagOperation {
    typealias Result = Void

    let image: Image
    let onSendImageProgress: OnSessionSendImageProgress?
    let onWaitForRefresh: OnSessionWaitForRefresh?

    init(
        image: Image,
        onSendImageProgress: OnSessionSendImageProgress?,
        onWaitForRefresh: OnSessionWaitForRefresh?
    ) {
        self.image = image
        self.onSendImageProgress = onSendImageProgress
        self.onWaitForRefresh = onWaitForRefresh
    }

    func perform(
        on tag: UncheckedSendable<NFCISO7816Tag>,
        context: ISO7816TagOperationContext
    ) async throws -> ISO7816TagOperationResult<Void> {
        try await tag.value.sendAPDUCommand(AuthAPDUCommand())

        if let update = await onSendImageProgress?(0.0), let message = update.message {
            await context.updateAlertMessage(message)
        }

        let commands = SendImageAPDUCommand.sendImageAPDUCommands(for: image)
        for (index, command) in commands.enumerated() {
            try await tag.value.sendAPDUCommand(command)

            let progress = Float(index + 1) / Float(commands.count)

            if let update = await onSendImageProgress?(progress), let message = update.message {
                await context.updateAlertMessage(message)
            }
        }

        if let update = await onWaitForRefresh?(false), let message = update.message {
            await context.updateAlertMessage(message)
        }

        // Refresh takes longer than 20-second especially for 4-color displays.
        // However, Core NFC forcibly invalidate connection after 20-second since `connect(to:)`.
        // Use blocking command which can extend connection until fresh is completed
        // instead of polling with `WaitForRefreshAPDUCommand()`.
        try await tag.value.sendAPDUCommand(RefreshAPDUCommand(waitForRefresh: true))

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
    onError: OnSessionError? = nil
) async throws {
    try await performOperation(
        SendImageOperation(
            image: image,
            onSendImageProgress: onSendImageProgress,
            onWaitForRefresh: onWaitForRefresh
        ),
        onBegin: onBegin,
        onError: onError
    )
}
