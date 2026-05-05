//
//  SendLogView.swift
//  EPaperNFCDemo
//

import SwiftUI

struct SendLogView: View {
    @Environment(SendLogStore.self)
    private var store

    var body: some View {
        List {
            Section {
                if store.entries.isEmpty {
                    Text("No attempts recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive) {
                        store.clear()
                    } label: {
                        Text("Clear all entries")
                    }
                }
            }

            ForEach(store.entries) { entry in
                NavigationLink {
                    SendLogDetailView(entry: entry)
                } label: {
                    SendLogRowView(entry: entry)
                }
            }
        }
        .navigationTitle("Send Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    let bundle = bundleAllAsText(store.entries)
                    ShareLink(
                        item: bundle,
                        preview: SharePreview("Send Log (\(store.entries.count))")
                    ) {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                }
            }
        }
    }
}

private func bundleAllAsText(_ entries: [SendLogEntry]) -> String {
    var lines: [String] = []
    lines.append("# Send Log Bundle")
    lines.append("count: \(entries.count)")
    let successes = entries.filter { $0.succeeded }.count
    lines.append("success: \(successes)")
    lines.append("failure: \(entries.count - successes)")
    lines.append("")
    for (i, entry) in entries.enumerated() {
        lines.append("================ entry \(i + 1)/\(entries.count) ================")
        lines.append(entry.renderedTrace())
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

private struct SendLogRowView: View {
    var entry: SendLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(entry.succeeded ? .green : .red)
                Text(entry.startedAt, format: .dateTime.month().day().hour().minute().second())
                    .font(.subheadline.monospacedDigit())
                Spacer()
                Text(String(format: "%.1fs", entry.totalElapsed))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let last = entry.lastPhaseLabel {
                Text("reached: \(last)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SendLogDetailView: View {
    var entry: SendLogEntry

    var body: some View {
        let trace = entry.renderedTrace()
        ScrollView {
            Text(trace)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(entry.succeeded ? "Success" : "Failure")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: trace) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }
}
