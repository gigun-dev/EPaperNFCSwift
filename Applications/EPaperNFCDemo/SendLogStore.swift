//
//  SendLogStore.swift
//  EPaperNFCDemo
//

import CoreNFC
import EPaperNFCSwift
import Foundation
import Observation

nonisolated struct PaletteBin: Codable, Hashable {
    var label: String
    var count: Int
}

nonisolated struct SendLogPhase: Codable, Hashable, Identifiable {
    var id: UUID
    var label: String
    var elapsedFromStart: TimeInterval
    var durationFromPrevious: TimeInterval

    init(label: String, elapsedFromStart: TimeInterval, durationFromPrevious: TimeInterval) {
        self.id = UUID()
        self.label = label
        self.elapsedFromStart = elapsedFromStart
        self.durationFromPrevious = durationFromPrevious
    }

    private enum CodingKeys: CodingKey {
        case id, label, elapsedFromStart, durationFromPrevious
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.label = try c.decode(String.self, forKey: .label)
        self.elapsedFromStart = try c.decode(TimeInterval.self, forKey: .elapsedFromStart)
        self.durationFromPrevious = try c.decode(TimeInterval.self, forKey: .durationFromPrevious)
    }
}

nonisolated struct SendLogEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var startedAt: Date
    var displayTypeID: String
    var dataByteCount: Int
    var phases: [SendLogPhase]
    var totalElapsed: TimeInterval
    var succeeded: Bool
    var errorDescription: String?
    // Last phase reached before the failure (or final phase on success).
    var lastPhaseLabel: String?
    // Refresh phase duration in seconds; nil if refresh never started.
    var refreshElapsed: TimeInterval?
    // Palette histogram captured from the dithered image data.
    var paletteHistogram: [PaletteBin]?

    init(
        startedAt: Date,
        displayTypeID: String,
        dataByteCount: Int,
        phases: [SendLogPhase],
        totalElapsed: TimeInterval,
        succeeded: Bool,
        errorDescription: String?,
        lastPhaseLabel: String?,
        refreshElapsed: TimeInterval?,
        paletteHistogram: [PaletteBin]?
    ) {
        self.id = UUID()
        self.startedAt = startedAt
        self.displayTypeID = displayTypeID
        self.dataByteCount = dataByteCount
        self.phases = phases
        self.totalElapsed = totalElapsed
        self.succeeded = succeeded
        self.errorDescription = errorDescription
        self.lastPhaseLabel = lastPhaseLabel
        self.refreshElapsed = refreshElapsed
        self.paletteHistogram = paletteHistogram
    }

    private enum CodingKeys: CodingKey {
        case id, startedAt, displayTypeID, dataByteCount, phases, totalElapsed,
             succeeded, errorDescription, lastPhaseLabel, refreshElapsed,
             paletteHistogram
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.displayTypeID = try c.decode(String.self, forKey: .displayTypeID)
        self.dataByteCount = try c.decode(Int.self, forKey: .dataByteCount)
        self.phases = (try? c.decodeIfPresent([SendLogPhase].self, forKey: .phases)) ?? []
        self.totalElapsed = try c.decode(TimeInterval.self, forKey: .totalElapsed)
        self.succeeded = try c.decode(Bool.self, forKey: .succeeded)
        self.errorDescription = try? c.decodeIfPresent(String.self, forKey: .errorDescription)
        self.lastPhaseLabel = try? c.decodeIfPresent(String.self, forKey: .lastPhaseLabel)
        self.refreshElapsed = try? c.decodeIfPresent(TimeInterval.self, forKey: .refreshElapsed)
        self.paletteHistogram = try? c.decodeIfPresent([PaletteBin].self, forKey: .paletteHistogram)
    }
}

extension SendLogEntry {
    var summary: String {
        let outcome = succeeded ? "✓ success" : "✗ failed"
        let last = lastPhaseLabel.map { " @ \($0)" } ?? ""
        return "\(outcome)\(last) — \(String(format: "%.1fs", totalElapsed))"
    }

    func renderedTrace() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = []
        lines.append("Started: \(formatter.string(from: startedAt))")
        lines.append("Display: \(displayTypeID)")
        lines.append("Bytes:   \(dataByteCount)")
        lines.append("Total:   \(String(format: "%.3fs", totalElapsed))")
        lines.append("Outcome: \(succeeded ? "success" : "failed")")
        if let lastPhaseLabel {
            lines.append("Reached: \(lastPhaseLabel)")
        }
        if let refreshElapsed {
            lines.append(String(format: "Refresh: %.3fs", refreshElapsed))
        }
        if let paletteHistogram, !paletteHistogram.isEmpty {
            let total = paletteHistogram.reduce(0) { $0 + $1.count }
            lines.append("Palette:")
            for bin in paletteHistogram {
                let pct = total > 0 ? Double(bin.count) / Double(total) * 100.0 : 0
                let label = bin.label.padding(toLength: 8, withPad: " ", startingAt: 0)
                lines.append(String(format: "  %@%7d  %5.1f%%", label, bin.count, pct))
            }
        }
        if let errorDescription {
            lines.append("")
            lines.append("Error:")
            for raw in errorDescription.split(separator: "\n") {
                lines.append("  \(raw)")
            }
        }
        lines.append("")
        lines.append("Phases:")
        for phase in phases {
            lines.append(String(format: "  %7.3fs  +%6.3fs  %@",
                phase.elapsedFromStart, phase.durationFromPrevious, phase.label))
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
@Observable
final class SendLogStore {
    static let shared = SendLogStore()

    private(set) var entries: [SendLogEntry] = []

    private let maxEntries = 50
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = dir.appendingPathComponent("send_log.json")
        load()
    }

    func append(_ entry: SendLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([SendLogEntry].self, from: data) {
            entries = decoded
        } else {
            // The persisted format must have changed in an incompatible way.
            // Salvage what we can by decoding entries one at a time so a
            // single malformed record doesn't drop the whole log.
            entries = decodePerEntry(data, decoder: decoder)
        }
    }

    private func decodePerEntry(_ data: Data, decoder: JSONDecoder) -> [SendLogEntry] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        var salvaged: [SendLogEntry] = []
        for item in raw {
            if let itemData = try? JSONSerialization.data(withJSONObject: item),
               let entry = try? decoder.decode(SendLogEntry.self, from: itemData) {
                salvaged.append(entry)
            }
        }
        return salvaged
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// Aggregator that collects phase events for a single send attempt. Lives
// outside any actor so the NFC operation's @Sendable callbacks can invoke it
// directly from background threads.
nonisolated final class SendLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private let monotonicStart: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var phases: [SendLogPhase] = []
    private var lastTimestamp: TimeInterval
    private var refreshStartTimestamp: TimeInterval?

    let displayTypeID: String
    let dataByteCount: Int
    let paletteHistogram: [PaletteBin]?

    nonisolated init(
        displayTypeID: String,
        dataByteCount: Int,
        paletteHistogram: [PaletteBin]? = nil
    ) {
        self.displayTypeID = displayTypeID
        self.dataByteCount = dataByteCount
        self.paletteHistogram = paletteHistogram
        self.lastTimestamp = monotonicStart
    }

    nonisolated func record(_ phase: SendImagePhase) {
        if case .refreshStarted = phase {
            lock.lock()
            refreshStartTimestamp = ProcessInfo.processInfo.systemUptime
            lock.unlock()
        }
        record(label(for: phase))
    }

    nonisolated func record(_ label: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let elapsed = now - monotonicStart
        let delta = now - lastTimestamp
        lastTimestamp = now
        phases.append(SendLogPhase(
            label: label,
            elapsedFromStart: elapsed,
            durationFromPrevious: delta
        ))
        lock.unlock()
    }

    nonisolated func finalize(error: (any Error)?) -> SendLogEntry {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let total = now - monotonicStart
        return SendLogEntry(
            startedAt: startedAt,
            displayTypeID: displayTypeID,
            dataByteCount: dataByteCount,
            phases: phases,
            totalElapsed: total,
            succeeded: error == nil,
            errorDescription: error.map { Self.describe($0) },
            lastPhaseLabel: phases.last?.label,
            refreshElapsed: refreshStartTimestamp.map { now - $0 },
            paletteHistogram: paletteHistogram
        )
    }

    nonisolated private func label(for phase: SendImagePhase) -> String {
        switch phase {
        case .auth: "auth"
        case .sendChunkStarted(let index, let count): "chunk-start \(index + 1)/\(count)"
        case .sendChunkCompleted(let index, let count): "chunk-done  \(index + 1)/\(count)"
        case .refreshStarted: "refresh-start"
        case .refreshCompleted: "refresh-done"
        }
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        var lines: [String] = []
        lines.append(String(reflecting: error))
        let ns = error as NSError
        lines.append("NSError.domain = \(ns.domain)")
        lines.append("NSError.code   = \(ns.code)")
        if ns.domain == NFCErrorDomain, let code = NFCReaderError.Code(rawValue: ns.code) {
            lines.append("NFCReaderError = \(nfcReaderErrorCaseName(code))")
        }
        if !ns.localizedDescription.isEmpty {
            lines.append("localized      = \(ns.localizedDescription)")
        }
        if !ns.userInfo.isEmpty {
            lines.append("userInfo:")
            for (key, value) in ns.userInfo.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(key) = \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated private func nfcReaderErrorCaseName(_ code: NFCReaderError.Code) -> String {
    switch code {
    case .readerSessionInvalidationErrorUserCanceled: "readerSessionInvalidationErrorUserCanceled"
    case .readerSessionInvalidationErrorSessionTimeout: "readerSessionInvalidationErrorSessionTimeout"
    case .readerSessionInvalidationErrorSessionTerminatedUnexpectedly: "readerSessionInvalidationErrorSessionTerminatedUnexpectedly"
    case .readerSessionInvalidationErrorSystemIsBusy: "readerSessionInvalidationErrorSystemIsBusy"
    case .readerSessionInvalidationErrorFirstNDEFTagRead: "readerSessionInvalidationErrorFirstNDEFTagRead"
    case .readerErrorUnsupportedFeature: "readerErrorUnsupportedFeature"
    case .readerErrorSecurityViolation: "readerErrorSecurityViolation"
    case .readerErrorInvalidParameter: "readerErrorInvalidParameter"
    case .readerErrorInvalidParameterLength: "readerErrorInvalidParameterLength"
    case .readerErrorParameterOutOfBound: "readerErrorParameterOutOfBound"
    case .readerErrorRadioDisabled: "readerErrorRadioDisabled"
    case .readerTransceiveErrorTagConnectionLost: "readerTransceiveErrorTagConnectionLost"
    case .readerTransceiveErrorRetryExceeded: "readerTransceiveErrorRetryExceeded"
    case .readerTransceiveErrorTagResponseError: "readerTransceiveErrorTagResponseError"
    case .readerTransceiveErrorSessionInvalidated: "readerTransceiveErrorSessionInvalidated"
    case .readerTransceiveErrorTagNotConnected: "readerTransceiveErrorTagNotConnected"
    case .readerTransceiveErrorPacketTooLong: "readerTransceiveErrorPacketTooLong"
    case .tagCommandConfigurationErrorInvalidParameters: "tagCommandConfigurationErrorInvalidParameters"
    case .ndefReaderSessionErrorTagNotWritable: "ndefReaderSessionErrorTagNotWritable"
    case .ndefReaderSessionErrorTagUpdateFailure: "ndefReaderSessionErrorTagUpdateFailure"
    case .ndefReaderSessionErrorTagSizeTooSmall: "ndefReaderSessionErrorTagSizeTooSmall"
    case .ndefReaderSessionErrorZeroLengthMessage: "ndefReaderSessionErrorZeroLengthMessage"
    @unknown default: "unknown(\(code.rawValue))"
    }
}
