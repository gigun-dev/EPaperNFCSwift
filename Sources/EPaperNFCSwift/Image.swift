//
//  Image.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/16/26.
//

import Foundation

public enum ImageError: Error {
    case invalidDataCount
    case invalidColorIndex
}

public struct Image: Equatable, Sendable {
    public let data: Data
    public let displayType: DisplayType

    private init(data: Data, displayType: DisplayType) {
        self.data = data
        self.displayType = displayType
    }

    public init(data: Data, for displayType: DisplayType) throws {
        let expectedDataCount = displayType.width * displayType.height
        guard data.count == expectedDataCount else {
            throw ImageError.invalidDataCount
        }

        let maxColorIndex = UInt8(displayType.colorPalette.colors.count - 1)
        guard data.allSatisfy({ $0 <= maxColorIndex }) else {
            throw ImageError.invalidColorIndex
        }

        self.data = data
        self.displayType = displayType
    }

    public static func demoImage(for displayType: DisplayType) -> Self {
        let width = displayType.width
        let height = displayType.height

        let halfWidth = width / 2
        let halfHeight = height / 2

        var data = Data(count: width * height)

        switch displayType.colorPalette {
        case .blackAndWhite:
            for y in 0..<height {
                for x in 0..<width {
                    let color: UInt8
                    if y < halfHeight {
                        color = x < halfWidth ? 0x01 : 0x00
                    } else {
                        color = x < halfWidth ? 0x00 : 0x01
                    }
                    data[y * width + x] = color
                }
            }

        case .blackWhiteYellowRed:
            for y in 0..<height {
                for x in 0..<width {
                    let color: UInt8
                    if y < halfHeight {
                        color = x < halfWidth ? 0x00 : 0x01
                    } else {
                        color = x < halfWidth ? 0x02 : 0x03
                    }
                    data[y * width + x] = color
                }
            }
        }

        return Image(data: data, displayType: displayType)
    }
}
