//
//  LZO.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/16/26.
//

import Foundation

// A sufficient implementation of LZO compression
// Based on <https://www.kernel.org/doc/Documentation/lzo.txt>
// Consulted with gpt-5.3-codex
func compress(_ data: Data) -> Data {
    let src = Array(data)
    let n = src.count
    var out = Data()

    // Empty stream.
    if n == 0 {
        out.append(contentsOf: [0x11, 0x00, 0x00])
        return out
    }

    struct Match {
        let start: Int
        let length: Int
        let distance: Int
    }

    @inline(__always)
    func hash3(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> Int {
        let v = (UInt32(b0) << 16) | (UInt32(b1) << 8) | UInt32(b2)
        return Int((v &* 2_654_435_761) >> 16) & 0xFFFF
    }

    @inline(__always)
    func appendLengthExtension(_ value: Int, to out: inout Data) {
        var v = value
        while v > 255 {
            out.append(0)
            v -= 255
        }
        out.append(UInt8(v))
    }

    @inline(__always)
    func appendLE16(_ v: Int, to out: inout Data) {
        out.append(UInt8(v & 0xff))
        out.append(UInt8((v >> 8) & 0xff))
    }

    // state == 0 required.
    func emitLongLiteral(start: Int, end: Int, to out: inout Data) {
        let len = end - start
        precondition(len >= 4)
        if len <= 18 {
            out.append(UInt8(len - 3))
        } else {
            out.append(0x00)
            appendLengthExtension(len - 18, to: &out)
        }
        out.append(contentsOf: src[start..<end])
    }

    // Returns state after emitting the first literal run.
    func emitFirstLiteral(start: Int, end: Int, to out: inout Data) -> Int {
        let len = end - start
        precondition(len > 0)
        if len <= 3 {
            out.append(UInt8(17 + len))
            out.append(contentsOf: src[start..<end])
            return len
        } else if len <= 238 {
            out.append(UInt8(17 + len))
            out.append(contentsOf: src[start..<end])
            return 4
        } else {
            emitLongLiteral(start: start, end: end, to: &out)
            return 4
        }
    }

    // state == 4 required. Encodes a 3-byte match from 2..3KB.
    func emitM1State4(distance: Int, state: Int, to out: inout Data) {
        precondition((2049...3072).contains(distance))
        precondition((0...3).contains(state))
        let d = distance - 2049
        out.append(UInt8(((d & 0x3) << 2) | state))
        out.append(UInt8((d >> 2) & 0xff))
    }

    // Copy 3..8 bytes from <=2KB distance.
    func emitM2(length: Int, distance: Int, state: Int, to out: inout Data) {
        precondition((3...8).contains(length))
        precondition((1...2048).contains(distance))
        precondition((0...3).contains(state))

        let d = distance - 1
        let dLow3 = (d & 0x7) << 2
        let high = UInt8((d >> 3) & 0xff)

        if length <= 4 {
            let l = (length - 3) << 5
            out.append(UInt8(0x40 | l | dLow3 | state))
        } else {
            let l = (length - 5) << 5
            out.append(UInt8(0x80 | l | dLow3 | state))
        }
        out.append(high)
    }

    // Copy >=3 bytes from <=16KB distance.
    func emitM3(length: Int, distance: Int, state: Int, to out: inout Data) {
        precondition(length >= 3)
        precondition((1...16384).contains(distance))
        precondition((0...3).contains(state))

        if length <= 33 {
            out.append(UInt8(0x20 | (length - 2)))
        } else {
            out.append(0x20)
            appendLengthExtension(length - 33, to: &out)
        }

        let packed = ((distance - 1) << 2) | state
        appendLE16(packed, to: &out)
    }

    // Copy >=3 bytes from 16KB..48KB distance (excluding EOS marker distance).
    func emitM4(length: Int, distance: Int, state: Int, to out: inout Data) {
        precondition(length >= 3)
        precondition((16385...49151).contains(distance))
        precondition((0...3).contains(state))

        let h = (distance >= 32768) ? 1 : 0
        if length <= 9 {
            out.append(UInt8(0x10 | (h << 3) | (length - 2)))
        } else {
            out.append(UInt8(0x10 | (h << 3)))
            appendLengthExtension(length - 9, to: &out)
        }

        let d = distance - 16384 - (h << 14)
        let packed = (d << 2) | state
        appendLE16(packed, to: &out)
    }

    func emitMatch(length: Int, distance: Int, state: Int, previousState: Int, to out: inout Data) {
        if previousState == 4 && length == 3 && (2049...3072).contains(distance) {
            emitM1State4(distance: distance, state: state, to: &out)
            return
        }

        if length <= 8 && distance <= 2048 {
            emitM2(length: length, distance: distance, state: state, to: &out)
            return
        }

        if distance <= 16384 {
            emitM3(length: length, distance: distance, state: state, to: &out)
            return
        }

        emitM4(length: length, distance: distance, state: state, to: &out)
    }

    let maxDistance = 49_151
    let maxMatchLen = 512
    var lastPos = Array(repeating: -1, count: 1 << 16)
    var matches: [Match] = []
    var i = 0
    while i + 2 < n {
        let h = hash3(src[i], src[i + 1], src[i + 2])
        let cand = lastPos[h]
        lastPos[h] = i

        var bestLen = 0
        var bestDist = 0

        if cand >= 0 {
            let dist = i - cand
            if dist <= maxDistance,
                src[cand] == src[i],
                src[cand + 1] == src[i + 1],
                src[cand + 2] == src[i + 2]
            {
                let maxLen = min(maxMatchLen, n - i)
                var len = 3
                while len < maxLen && src[cand + len] == src[i + len] {
                    len += 1
                }
                let minUsefulLen = (dist <= 2048) ? 3 : 4
                if len >= minUsefulLen {
                    bestLen = len
                    bestDist = dist
                }
            }
        }

        if bestLen > 0 {
            matches.append(Match(start: i, length: bestLen, distance: bestDist))
            var k = 1
            while k < bestLen && i + k + 2 < n {
                let hk = hash3(src[i + k], src[i + k + 1], src[i + k + 2])
                lastPos[hk] = i + k
                k += 1
            }
            i += bestLen
        } else {
            i += 1
        }
    }

    if matches.isEmpty {
        _ = emitFirstLiteral(start: 0, end: n, to: &out)
        out.append(contentsOf: [0x11, 0x00, 0x00])
        return out
    }

    let firstLiteralLen = matches[0].start
    precondition(firstLiteralLen > 0)
    var state = emitFirstLiteral(start: 0, end: firstLiteralLen, to: &out)

    for idx in matches.indices {
        let m = matches[idx]
        let matchEnd = m.start + m.length
        let nextStart = (idx + 1 < matches.count) ? matches[idx + 1].start : n
        let gap = nextStart - matchEnd
        precondition(gap >= 0)

        if gap <= 3 {
            emitMatch(length: m.length, distance: m.distance, state: gap, previousState: state, to: &out)
            if gap > 0 {
                out.append(contentsOf: src[matchEnd..<(matchEnd + gap)])
            }
            state = gap
        } else {
            emitMatch(length: m.length, distance: m.distance, state: 0, previousState: state, to: &out)
            state = 0
            emitLongLiteral(start: matchEnd, end: nextStart, to: &out)
            state = 4
        }
    }

    out.append(contentsOf: [0x11, 0x00, 0x00])
    return out
}
