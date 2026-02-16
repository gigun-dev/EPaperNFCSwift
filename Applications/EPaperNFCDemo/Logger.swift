//
//  Logger.swift
//  EPaperNFCDemo
//
//  Created by Yoshimasa Niwa on 2/21/26.
//

import OSLog

extension Logger {
    nonisolated func error(_ error: some Error) {
        self.error("\(error, privacy: .public)")
    }
}
