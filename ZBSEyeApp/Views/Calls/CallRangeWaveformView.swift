import SwiftUI

struct CallRangeWaveformView: View {
    let totalSeconds: Double
    let microphone: [Double]
    let system: [Double]
    @Binding var startSeconds: Double
    @Binding var endSeconds: Double

    @State private var dragMode: DragMode?
    @State private var dragAnchor: Double = 0

    private enum DragMode { case start, end, newSelection }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let startX = x(for: startSeconds, width: width)
            let endX = x(for: endSeconds, width: width)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.55))

                waveformCanvas
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)

                if hasSelection {
                    Rectangle()
                        .fill(.black.opacity(0.28))
                        .frame(width: startX)
                    Rectangle()
                        .fill(.black.opacity(0.28))
                        .frame(width: max(0, width - endX))
                        .offset(x: endX)
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: max(1, endX - startX), height: proxy.size.height)
                        .offset(x: startX)

                    handle(at: startX, pointsRight: true, height: proxy.size.height)
                    handle(at: endX, pointsRight: false, height: proxy.size.height)
                } else {
                    Text("Drag across the recording to select audio")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(selectionGesture(width: width))
        }
        .frame(height: trackHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio range selector")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Drag to select audio. Drag either blue edge to refine the range.")
    }

    private var waveformCanvas: some View {
        Canvas { context, size in
            let tracks: [(values: [Double], center: CGFloat, color: Color)]
            if !microphone.isEmpty, !system.isEmpty {
                tracks = [
                    (microphone, size.height * 0.27, .red),
                    (system, size.height * 0.73, .blue),
                ]
            } else if !microphone.isEmpty {
                tracks = [(microphone, size.height * 0.5, .red)]
            } else if !system.isEmpty {
                tracks = [(system, size.height * 0.5, .blue)]
            } else {
                tracks = []
            }

            for track in tracks {
                let step = size.width / CGFloat(max(1, track.values.count))
                let maximumHalfHeight = tracks.count == 1 ? size.height * 0.38 : size.height * 0.18
                for (index, value) in track.values.enumerated() where value > 0 {
                    let height = max(2, maximumHalfHeight * CGFloat(value))
                    let x = (CGFloat(index) + 0.5) * step
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: track.center - height))
                    path.addLine(to: CGPoint(x: x, y: track.center + height))
                    context.stroke(
                        path,
                        with: .color(track.color.opacity(0.82)),
                        style: StrokeStyle(lineWidth: max(1, min(2.5, step * 0.65)), lineCap: .round)
                    )
                }
            }
        }
    }

    private func handle(at x: CGFloat, pointsRight: Bool, height: CGFloat) -> some View {
        ZStack {
            Capsule().fill(Color.accentColor).frame(width: 5, height: height)
            Image(systemName: pointsRight ? "chevron.right" : "chevron.left")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 20, height: 28)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
        }
        .frame(width: 20, height: height)
        .offset(x: x - 10)
        .allowsHitTesting(false)
    }

    private func selectionGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let seconds = seconds(for: value.location.x, width: width)
                if dragMode == nil {
                    let startDistance = abs(value.startLocation.x - x(for: startSeconds, width: width))
                    let endDistance = abs(value.startLocation.x - x(for: endSeconds, width: width))
                    if hasSelection, startDistance <= 18, startDistance <= endDistance {
                        dragMode = .start
                    } else if hasSelection, endDistance <= 18 {
                        dragMode = .end
                    } else {
                        dragMode = .newSelection
                        dragAnchor = seconds
                        startSeconds = seconds
                        endSeconds = seconds
                    }
                }

                switch dragMode {
                case .start:
                    startSeconds = min(max(0, seconds), max(0, endSeconds - 0.5))
                case .end:
                    endSeconds = max(min(totalSeconds, seconds), min(totalSeconds, startSeconds + 0.5))
                case .newSelection:
                    startSeconds = min(dragAnchor, seconds)
                    endSeconds = max(dragAnchor, seconds)
                case nil:
                    break
                }
            }
            .onEnded { _ in dragMode = nil }
    }

    private var hasSelection: Bool { endSeconds - startSeconds >= 0.5 }
    private var trackHeight: CGFloat { microphone.isEmpty != system.isEmpty ? 92 : 118 }

    private func x(for seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat(min(1, max(0, seconds / max(1, totalSeconds)))) * width
    }

    private func seconds(for x: CGFloat, width: CGFloat) -> Double {
        Double(min(1, max(0, x / max(1, width)))) * totalSeconds
    }

    private var accessibilityValue: String {
        guard hasSelection else { return String(localized: "No selection") }
        return String(localized: "From \(clock(startSeconds)) to \(clock(endSeconds))")
    }

    private func clock(_ seconds: Double) -> String {
        let value = max(0, Int64(seconds))
        return String(format: "%02lld:%02lld", value / 60, value % 60)
    }
}
