//
//  DeviceInfo.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/16/26.
//

import Foundation

public struct DeviceInfo: Hashable, Identifiable, Sendable {
    public var id: UInt32
    public var name: String
    public var displayType: DisplayType

    public init(
        id: UInt32,
        name: String,
        displayType: DisplayType
    ) {
        self.id = id
        self.name = name
        self.displayType = displayType
    }
}
