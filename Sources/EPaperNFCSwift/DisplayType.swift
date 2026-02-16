//
//  DisplayType.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/19/26.
//

public struct DisplayType: Hashable, Identifiable, Sendable {
    public enum ColorPalette: Sendable {
        case blackAndWhite
        case blackWhiteYellowRed

        public struct Color: Hashable, Sendable {
            public var r: UInt8
            public var g: UInt8
            public var b: UInt8
        }

        public var colors: [Color] {
            switch self {
            case .blackAndWhite:
                [
                    // Black
                    Color(r: 0x00, g: 0x00, b: 0x00),
                    // White
                    Color(r: 0xFF, g: 0xFF, b: 0xFF)
                ]
            case .blackWhiteYellowRed:
                [
                    // Black
                    Color(r: 0x00, g: 0x00, b: 0x00),
                    // White
                    Color(r: 0xFF, g: 0xFF, b: 0xFF),
                    // Yellow
                    Color(r: 0xFF, g: 0xCC, b: 0x00),
                    // Red
                    Color(r: 0xCC, g: 0x00, b: 0x00)
                ]
            }
        }
    }

    public enum Orientation: Sendable {
        case normal
        case rotated
    }

    public var id: Self {
        self
    }

    public var colorPalette: ColorPalette
    public var orientation: Orientation
    public var width: Int
    public var height: Int
}

extension DisplayType {
    public static let allDisplayTypes: [DisplayType] = [
        .twoPointNineInchBlackAndWhite,
        .twoPointNineInchBlackWhiteYellowRed,
        .fourPointTwoInchBlackAndWhite,
        .fourPointTwoInchBlackWhiteYellowRed
    ]

    public static let twoPointNineInchBlackAndWhite = DisplayType(
        colorPalette: .blackAndWhite,
        orientation: .rotated,
        width: 296,
        height: 128
    )

    public static let twoPointNineInchBlackWhiteYellowRed = DisplayType(
        colorPalette: .blackWhiteYellowRed,
        orientation: .rotated,
        width: 296,
        height: 128
    )

    public static let fourPointTwoInchBlackAndWhite = DisplayType(
        colorPalette: .blackAndWhite,
        orientation: .normal,
        width: 400,
        height: 300
    )

    public static let fourPointTwoInchBlackWhiteYellowRed = DisplayType(
        colorPalette: .blackWhiteYellowRed,
        orientation: .normal,
        width: 400,
        height: 300
    )
}
