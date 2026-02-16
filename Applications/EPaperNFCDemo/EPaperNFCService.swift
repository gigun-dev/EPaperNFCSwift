//
//  EPaperNFCService.swift
//  EPaperNFCDemo
//
//  Created by Yoshimasa Niwa on 2/20/26.
//

import EPaperNFCSwift
import Foundation
import Observation

@MainActor
protocol EPaperNFCServiceProtocol: AnyObject, Observable {
    func deviceInfo(
        onBegin: @escaping OnSessionBegin,
        onError: @escaping OnSessionError
    ) async throws -> DeviceInfo

    func sendImage(
        _ image: Image,
        onBegin: @escaping OnSessionBegin,
        onSendImageProgress: @escaping OnSessionSendImageProgress,
        onWaitForRefresh: @escaping OnSessionWaitForRefresh,
        onError: @escaping OnSessionError
    ) async throws -> Void
}

@MainActor
@Observable
final class AnyEPaperNFCService: EPaperNFCServiceProtocol {
    private let service: any EPaperNFCServiceProtocol

    init(_ service: some EPaperNFCServiceProtocol) {
        self.service = service
    }

    func deviceInfo(
        onBegin: @escaping OnSessionBegin,
        onError: @escaping OnSessionError
    ) async throws -> DeviceInfo {
        try await service.deviceInfo(
            onBegin: onBegin,
            onError: onError
        )
    }

    func sendImage(
        _ image: Image,
        onBegin: @escaping OnSessionBegin,
        onSendImageProgress: @escaping OnSessionSendImageProgress,
        onWaitForRefresh: @escaping OnSessionWaitForRefresh,
        onError: @escaping OnSessionError
    ) async throws -> Void {
        try await service.sendImage(
            image,
            onBegin: onBegin,
            onSendImageProgress: onSendImageProgress,
            onWaitForRefresh: onWaitForRefresh,
            onError: onError
        )
    }
}

extension EPaperNFCServiceProtocol {
    func eraseToAnyEPaperNFCService() -> AnyEPaperNFCService {
        AnyEPaperNFCService(self)
    }
}

@MainActor
@Observable
final class EPaperNFCService: EPaperNFCServiceProtocol {
    func deviceInfo(
        onBegin: @escaping OnSessionBegin,
        onError: @escaping OnSessionError
    ) async throws -> DeviceInfo {
        try await EPaperNFCSwift.deviceInfo(
            onBegin: onBegin,
            onError: onError
        )
    }

    func sendImage(
        _ image: Image,
        onBegin: @escaping OnSessionBegin,
        onSendImageProgress: @escaping OnSessionSendImageProgress,
        onWaitForRefresh: @escaping OnSessionWaitForRefresh,
        onError: @escaping OnSessionError
    ) async throws -> Void {
        try await EPaperNFCSwift.sendImage(
            image,
            onBegin: onBegin,
            onSendImageProgress: onSendImageProgress,
            onWaitForRefresh: onWaitForRefresh,
            onError: onError
        )
    }}

@MainActor
@Observable
final class PreviewEPaperNFCService: EPaperNFCServiceProtocol {
    func deviceInfo(
        onBegin: OnSessionBegin,
        onError: OnSessionError
    ) async throws -> DeviceInfo {
        _ = await onBegin()
        try await Task.sleep(for: .seconds(1.0))

        let displayType = DisplayType.allDisplayTypes.randomElement()!
        return DeviceInfo(id: 0x12345678, name: "Preview", displayType: displayType)
    }

    func sendImage(
        _ image: Image,
        onBegin: OnSessionBegin,
        onSendImageProgress: OnSessionSendImageProgress,
        onWaitForRefresh: OnSessionWaitForRefresh,
        onError: OnSessionError
    ) async throws -> Void {
        _ = await onBegin()

        try await Task.sleep(for: .seconds(2.0))

        for progress in 0..<100 {
            _ = await onSendImageProgress(Float(progress) / 100)
            try await Task.sleep(for: .milliseconds(10))
        }

        for _ in 0..<10 {
            _ = await onWaitForRefresh(false)
            try await Task.sleep(for: .milliseconds(500))
        }
        _ = await onWaitForRefresh(true)
    }
}
