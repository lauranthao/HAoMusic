// Verbatim extract from Coda (AGPL-3.0; see CodaPlayerControls.swift header).
// Playback and volume rails: DesignSystem/Components.swift.
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Playback and volume rails

/// Visual values shared by the playback scrubber and the system volume rail.
enum NowPlayingSliderStyle {
    static let trackHeight: CGFloat = 5
    static let trackOpacity: Double = 0.25
    static let draggingThumbDiameter: CGFloat = 13
    static let hoveringThumbDiameter: CGFloat = 11
    static let thumbShadowOpacity: Double = 0.3
    static let thumbShadowRadius: CGFloat = 2
    static let thumbShadowOffset: CGFloat = 1
}

/// Shared drawing only; each control keeps its own playback/system-volume interaction.
struct PlayerSliderRail: View {
    var fraction: Double
    var axis: Axis = .horizontal
    var fillColor: Color = .white
    var trackColor: Color = .white.opacity(NowPlayingSliderStyle.trackOpacity)
    var trackHeight: CGFloat = NowPlayingSliderStyle.trackHeight
    var thumbDiameter: CGFloat = NowPlayingSliderStyle.draggingThumbDiameter
    var showsThumb = false

    var body: some View {
        GeometryReader { geometry in
            let horizontal = axis == .horizontal
            let length = max(0, horizontal ? geometry.size.width : geometry.size.height)
            let value = fraction.isFinite ? min(max(fraction, 0), 1) : 0
            let filledLength = length * value
            let thickness = trackHeight
            ZStack(alignment: horizontal ? .leading : .bottom) {
                Capsule()
                    .fill(trackColor)
                    .frame(width: horizontal ? length : thickness,
                           height: horizontal ? thickness : length)
                Capsule()
                    .fill(fillColor)
                    .frame(width: horizontal ? filledLength : thickness,
                           height: horizontal ? thickness : filledLength)
                    .opacity(value > 0 ? 1 : 0)
                Circle()
                    .fill(.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    // Animate the thumb size without springing its final position.
                    .animation(.spring(response: 0.24, dampingFraction: 0.72), value: thumbDiameter)
                    .shadow(color: .black.opacity(NowPlayingSliderStyle.thumbShadowOpacity),
                            radius: NowPlayingSliderStyle.thumbShadowRadius,
                            y: NowPlayingSliderStyle.thumbShadowOffset)
                    .offset(x: horizontal ? filledLength - thumbDiameter / 2 : 0,
                            y: horizontal ? 0 : -filledLength + thumbDiameter / 2)
                    .opacity(showsThumb ? 1 : 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }
}


/// Shared rail, hit testing, drag mapping and pointer feedback for every player slider.
struct PlayerSlider: View {
    var fraction: Double
    var axis: Axis = .horizontal
    var fillColor: Color = .white
    var trackColor: Color = .white.opacity(NowPlayingSliderStyle.trackOpacity)
    var trackHeight: CGFloat = NowPlayingSliderStyle.trackHeight
    var onChanged: (Double) -> Void
    var onEnded: (Double) -> Void = { _ in }
    var onCancelled: () -> Void = { }

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var acceptedGesture = false
    @GestureState private var gestureIsActive = false

    var body: some View {
        GeometryReader { geometry in
            PlayerSliderRail(
                fraction: fraction, axis: axis, fillColor: fillColor, trackColor: trackColor,
                trackHeight: trackHeight,
                thumbDiameter: isDragging ? NowPlayingSliderStyle.draggingThumbDiameter
                    : NowPlayingSliderStyle.hoveringThumbDiameter,
                showsThumb: isDragging || isHovering
            )
            .contentShape(Rectangle())
            #if os(macOS)
            .overlay {
                PlayerSliderMouseInput(
                    onChanged: { point in
                        guard let fraction = fraction(at: point, size: geometry.size) else { return }
                        acceptedGesture = true
                        isDragging = true
                        onChanged(fraction)
                    },
                    onEnded: { point in
                        if acceptedGesture, let fraction = fraction(at: point, size: geometry.size) {
                            onEnded(fraction)
                        }
                        acceptedGesture = false
                        isDragging = false
                    },
                    onCancelled: {
                        if acceptedGesture { onCancelled() }
                        acceptedGesture = false
                        isDragging = false
                    }
                )
            }
            #else
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($gestureIsActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard acceptedGesture || CGRect(origin: .zero, size: geometry.size)
                            .contains(value.startLocation),
                              let fraction = fraction(at: value.location, size: geometry.size) else { return }
                        acceptedGesture = true
                        isDragging = true
                        onChanged(fraction)
                    }
                    .onEnded { value in
                        if acceptedGesture, let fraction = fraction(at: value.location, size: geometry.size) {
                            onEnded(fraction)
                        }
                        isDragging = false
                        acceptedGesture = false
                    }
            )
            #endif
        }
        .onHover { isHovering = $0 }
        .onChange(of: gestureIsActive) { active in
            guard !active else { return }
            DispatchQueue.main.async {
                guard !gestureIsActive else { return }
                if acceptedGesture { onCancelled() }
                acceptedGesture = false
                isDragging = false
            }
        }
        .onDisappear {
            if acceptedGesture { onCancelled() }
            acceptedGesture = false
            isDragging = false
        }
    }

    private func fraction(at point: CGPoint, size: CGSize) -> Double? {
        let length = axis == .horizontal ? size.width : size.height
        let position = axis == .horizontal ? point.x : size.height - point.y
        guard length.isFinite, length > 0, position.isFinite else { return nil }
        return Double(min(max(position / length, 0), 1))
    }
}

#if os(macOS)
/// Own the mouse sequence so AppKit cannot turn a slider drag into a window drag.
private struct PlayerSliderMouseInput: NSViewRepresentable {
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void

    func makeNSView(context: Context) -> InputView { InputView() }

    func updateNSView(_ view: InputView, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onCancelled = onCancelled
    }

    static func dismantleNSView(_ view: InputView, coordinator: ()) {
        view.cancelDrag()
    }

    final class InputView: NSView {
        var onChanged: (CGPoint) -> Void = { _ in }
        var onEnded: (CGPoint) -> Void = { _ in }
        var onCancelled: () -> Void = { }
        private var isDragging = false

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            isDragging = true
            onChanged(convert(event.locationInWindow, from: nil))
        }

        override func mouseDragged(with event: NSEvent) {
            guard isDragging else { return }
            onChanged(convert(event.locationInWindow, from: nil))
        }

        override func mouseUp(with event: NSEvent) {
            guard isDragging else { return }
            isDragging = false
            onEnded(convert(event.locationInWindow, from: nil))
        }

        func cancelDrag() {
            guard isDragging else { return }
            isDragging = false
            onCancelled()
        }
    }
}
#endif

/// Shared cover geometry for the full player and its bottom controls.
