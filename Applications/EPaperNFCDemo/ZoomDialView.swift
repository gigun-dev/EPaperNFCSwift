//
//  ZoomDialView.swift
//  EPaperNFCDemo
//

import SwiftUI

// iOS Camera-style zoom control. Compact pill shows one button per physical
// lens (e.g. .5x and 1x for the dual-wide camera). Tapping a button snaps
// the zoom; long-pressing a button expands a fan wheel above the pill that
// can be dragged left/right for continuous fine zoom in 0.1× increments,
// matching the system Camera app.
struct ZoomDialView: View {
    let displayZoom: CGFloat
    let lensSnapPoints: [CGFloat]   // only points corresponding to physical lenses
    let displayRange: ClosedRange<CGFloat>
    var onZoomChanged: (CGFloat) -> Void

    @State private var isWheelOpen: Bool = false
    @State private var wheelDragStartZoom: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 8) {
            if isWheelOpen {
                FanWheel(
                    displayZoom: displayZoom,
                    displayRange: displayRange,
                    lensSnapPoints: lensSnapPoints
                )
                .frame(height: 88)
                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
            }
            // Pill stays in the layout so the in-flight long-press+drag
            // gesture isn't dropped, but it visually disappears while the
            // wheel is shown — otherwise its "1×" duplicates the wheel's
            // yellow indicator.
            compactPill
                .opacity(isWheelOpen ? 0 : 1)
        }
        .animation(.spring(duration: 0.25), value: isWheelOpen)
    }

    private var compactPill: some View {
        HStack(spacing: 4) {
            ForEach(lensSnapPoints, id: \.self) { snap in
                snapButton(for: snap)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.5), in: Capsule())
    }

    @ViewBuilder
    private func snapButton(for snap: CGFloat) -> some View {
        let isCurrent = isCurrentSnap(snap)
        Text(buttonLabel(for: snap, isCurrent: isCurrent))
            .font(.system(size: isCurrent ? 13 : 11, weight: .semibold))
            .foregroundStyle(isCurrent ? .yellow : .white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(isCurrent ? Color.black.opacity(0.7) : Color.clear))
            .contentShape(Circle())
            .onTapGesture {
                onZoomChanged(snap)
            }
            .gesture(longPressDragGesture)
    }

    private var longPressDragGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first:
                    break
                case .second(_, let drag):
                    if !isWheelOpen {
                        isWheelOpen = true
                        // Anchor the wheel drag to the CURRENT zoom — long-
                        // pressing a button must not reset the value (matches
                        // iOS Camera).
                        wheelDragStartZoom = displayZoom
                    }
                    if let drag {
                        // iOS Camera convention: drag LEFT to zoom in, RIGHT to
                        // zoom out. Continuous zoom — display formatting
                        // rounds to 0.1× but the underlying value is smooth.
                        let octaves = -drag.translation.width / 80.0
                        let raw = wheelDragStartZoom * pow(2, octaves)
                        let clamped = max(displayRange.lowerBound, min(displayRange.upperBound, raw))
                        onZoomChanged(clamped)
                    }
                }
            }
            .onEnded { _ in
                isWheelOpen = false
            }
    }

    private func isCurrentSnap(_ snap: CGFloat) -> Bool {
        let sorted = lensSnapPoints.sorted()
        var current = sorted.first ?? snap
        for s in sorted where s <= displayZoom + 0.02 {
            current = s
        }
        return abs(current - snap) < 0.001
    }

    private func buttonLabel(for snap: CGFloat, isCurrent: Bool) -> String {
        // Active button shows × (e.g. ".5×" or "1×"); inactive shows the bare
        // value ("1", "2"). When current zoom is between snaps, the closest
        // active button shows the actual zoom (e.g. "1.5×").
        if isCurrent {
            if abs(displayZoom - snap) > 0.05 {
                return formatZoom(displayZoom)
            }
            return formatZoom(snap)
        }
        return formatSnap(snap)
    }

    private func formatSnap(_ value: CGFloat) -> String {
        if value < 1 {
            return ".\(Int(round(value * 10)))"
        }
        return "\(Int(round(value)))"
    }

    private func formatZoom(_ value: CGFloat) -> String {
        // Display rounds to 0.1× so the label doesn't shimmer between every
        // continuous-zoom update.
        let r = (value * 10).rounded() / 10
        if r < 1 { return String(format: "%.1f×", r) }
        if abs(r - r.rounded()) < 0.05 { return "\(Int(r.rounded()))×" }
        return String(format: "%.1f×", r)
    }
}

// Half-fan wheel matching iOS Camera's expanded zoom dial. The wheel is a
// dark CIRCLE positioned mostly below the visible canvas — only the top
// arc shows, producing the bulged half-disc silhouette of the system app.
// Tick marks and snap labels follow the curved top edge.
private struct FanWheel: View {
    let displayZoom: CGFloat
    let displayRange: ClosedRange<CGFloat>
    let lensSnapPoints: [CGFloat]

    private let dialRadius: CGFloat = 240
    private let topInset: CGFloat = 18  // distance from canvas top to highest point of wheel
    private let arcHalfSpanDegrees: Double = 45

    var body: some View {
        GeometryReader { geo in
            let centerX = geo.size.width / 2
            let centerY = topInset + dialRadius  // wheel center is below the canvas top
            let center = CGPoint(x: centerX, y: centerY)

            Canvas { context, size in
                drawBackground(context: context, size: size, center: center)
                drawTicks(context: context, center: center)
                drawLabels(context: context, center: center)
            }
            .clipped()
            .overlay(alignment: .top) {
                // Indicator + label group sits *inside* the dome, just below
                // the curved top edge. Triangle points down at the current
                // tick on the wheel (which is one of the major lens marks
                // when zoom is parked on a snap, otherwise a minor tick).
                VStack(spacing: 1) {
                    Triangle()
                        .fill(.yellow)
                        .frame(width: 7, height: 5)
                    Text(formatZoom(displayZoom))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.yellow)
                    if let mm = focalLengthIfOnLens(displayZoom) {
                        Text(mm)
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(.yellow.opacity(0.85))
                    }
                }
                .padding(.top, topInset + 4)
            }
        }
    }

    private func focalLength(for snap: CGFloat) -> String {
        // 1× wide ≈ 26mm equiv on iPhone main lenses. Linear scaling matches
        // 0.5× → 13mm, 2× → 52mm, 3× → 77mm.
        let mm = Int(round(snap * 26))
        return "\(mm)MM"
    }

    // mm is only shown when zoom is parked exactly on a lens snap; digital
    // zoom positions (e.g. 0.6×, 1.5×) suppress it.
    private func focalLengthIfOnLens(_ zoom: CGFloat) -> String? {
        for snap in lensSnapPoints where abs(snap - zoom) < 0.04 {
            return focalLength(for: snap)
        }
        return nil
    }

    private func drawBackground(context: GraphicsContext, size: CGSize, center: CGPoint) {
        // A full circle whose top arc is the visible wheel silhouette. The
        // canvas clips off the bottom so the user sees a curved dome.
        let r = dialRadius
        let rect = CGRect(
            x: center.x - r,
            y: center.y - r,
            width: 2 * r,
            height: 2 * r
        )
        context.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.55)))
    }

    private func drawTicks(context: GraphicsContext, center: CGPoint) {
        // Minor ticks first, then snap-point ticks on top so the major ones
        // visually punch through.
        var z = displayRange.lowerBound
        let stepFactor: CGFloat = 1.05
        while z <= displayRange.upperBound + 0.001 {
            if !isLensSnap(z) {
                drawTick(context: context, center: center, zoom: z, isMajor: false)
            }
            z *= stepFactor
        }
        for snap in lensSnapPoints {
            drawTick(context: context, center: center, zoom: snap, isMajor: true)
        }
    }

    private func drawTick(context: GraphicsContext, center: CGPoint, zoom: CGFloat, isMajor: Bool) {
        let visualAngle = angle(for: zoom) - angle(for: displayZoom)
        guard abs(visualAngle) <= arcHalfSpanDegrees else { return }
        let radians = visualAngle * .pi / 180
        let outerR = dialRadius - 6
        let tickLen: CGFloat = isMajor ? 12 : 5
        let innerR = outerR - tickLen
        let p1 = CGPoint(
            x: center.x + sin(radians) * innerR,
            y: center.y - cos(radians) * innerR
        )
        let p2 = CGPoint(
            x: center.x + sin(radians) * outerR,
            y: center.y - cos(radians) * outerR
        )
        var path = Path()
        path.move(to: p1)
        path.addLine(to: p2)
        // The snap tick that matches the current zoom turns yellow to match
        // the indicator. Major snaps are slightly thicker than minor ticks
        // but not chunky.
        let isCurrentLens = isMajor && abs(visualAngle) < 1.0
        context.stroke(
            path,
            with: .color(isCurrentLens ? .yellow : .white.opacity(isMajor ? 0.95 : 0.32)),
            lineWidth: isMajor ? 1.5 : 1
        )
    }

    private func drawLabels(context: GraphicsContext, center: CGPoint) {
        for snap in lensSnapPoints {
            // Skip when this snap is the current selection — the central
            // yellow indicator already shows it.
            let visualAngle = angle(for: snap) - angle(for: displayZoom)
            if abs(visualAngle) > arcHalfSpanDegrees { continue }
            if abs(visualAngle) < 5 { continue }

            let radians = visualAngle * .pi / 180
            let labelR = dialRadius - 38
            let pos = CGPoint(
                x: center.x + sin(radians) * labelR,
                y: center.y - cos(radians) * labelR
            )

            let valueResolved = context.resolve(
                Text(formatSnap(snap))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            )
            let valueSize = valueResolved.measure(in: CGSize(width: 60, height: 20))
            context.draw(
                valueResolved,
                in: CGRect(
                    x: pos.x - valueSize.width / 2,
                    y: pos.y - valueSize.height,
                    width: valueSize.width,
                    height: valueSize.height
                )
            )

            let mmResolved = context.resolve(
                Text(focalLength(for: snap))
                    .font(.system(size: 8, weight: .regular))
                    .foregroundColor(.white.opacity(0.65))
            )
            let mmSize = mmResolved.measure(in: CGSize(width: 60, height: 14))
            context.draw(
                mmResolved,
                in: CGRect(
                    x: pos.x - mmSize.width / 2,
                    y: pos.y + 1,
                    width: mmSize.width,
                    height: mmSize.height
                )
            )
        }
    }

    private func isLensSnap(_ z: CGFloat) -> Bool {
        lensSnapPoints.contains(where: { abs($0 - z) < 0.001 })
    }

    private func angle(for zoom: CGFloat) -> Double {
        let logMin = log(Double(displayRange.lowerBound))
        let logMax = log(Double(displayRange.upperBound))
        let logZoom = log(Double(zoom))
        let normalized = (logZoom - logMin) / (logMax - logMin)
        return -arcHalfSpanDegrees + 2 * arcHalfSpanDegrees * normalized
    }

    private func formatSnap(_ value: CGFloat) -> String {
        if value < 1 { return String(format: ".%d", Int(round(value * 10))) }
        return "\(Int(round(value)))"
    }

    private func formatZoom(_ value: CGFloat) -> String {
        // Display rounds to 0.1× so the label doesn't shimmer between every
        // continuous-zoom update.
        let r = (value * 10).rounded() / 10
        if r < 1 { return String(format: "%.1f×", r) }
        if abs(r - r.rounded()) < 0.05 { return "\(Int(r.rounded()))×" }
        return String(format: "%.1f×", r)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
