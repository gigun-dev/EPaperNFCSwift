//
//  ISO7816APDUCommand.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/19/26.
//

import CoreNFC
import Foundation

extension Data {
    func asTLV() -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        var index = startIndex

        while index < endIndex {
            guard index + 1 < endIndex else {
                break
            }

            let tag = self[index]
            let length = Int(self[index + 1])

            let valueStart = index + 2
            let valueEnd = valueStart + length

            guard valueEnd <= endIndex else {
                break
            }

            result[tag] = Data(self[valueStart..<valueEnd])

            index = valueEnd
        }
        return result
    }
}

// TODO: Rename errors
public enum ISO7816APDUCommandError: Error {
    case invalidData
    case failure(NFCISO7816ResponseAPDU)
    case invalidResponsePayload
}

protocol ISO7816APDUResponse: Sendable {
    init(response: NFCISO7816ResponseAPDU) throws
}

struct EmptyISO7816APDUResponse: ISO7816APDUResponse {
    init(response: NFCISO7816ResponseAPDU) throws {
    }
}

protocol ISO7816APDUCommand: Sendable {
    associatedtype Response: ISO7816APDUResponse

    var data: Data { get }
}

struct ISO7816APDUResponseStatus: Equatable {
    var word1: UInt8
    var word2: UInt8
}

extension ISO7816APDUResponseStatus {
    static let success = Self(word1: 0x90, word2: 0x00)
}

extension NFCISO7816ResponseAPDU {
    var status: ISO7816APDUResponseStatus {
        .init(word1: statusWord1, word2: statusWord2)
    }
}

extension NFCISO7816Tag {
    @concurrent
    @discardableResult
    func sendAPDUCommand<Command: ISO7816APDUCommand>(_ command: Command) async throws -> Command.Response {
        guard let apdu = NFCISO7816APDU(data: command.data) else {
            throw ISO7816APDUCommandError.invalidData
        }

        let response: NFCISO7816ResponseAPDU = try await sendCommand(apdu: apdu)

        switch response.status {
        case .success:
            return try Command.Response(response: response)
        default:
            throw ISO7816APDUCommandError.failure(response)
        }
    }
}
