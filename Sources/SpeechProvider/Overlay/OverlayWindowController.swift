import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let panel: NSPanel
    private let hostingView: DraggableHostingView
    private let sizeDefaults = UserDefaults.standard
    private let widthKey = "overlayWidth"
    private let heightKey = "overlayHeight"
    private var captions: [OverlayCaption] = []

    init() {
        let defaultSize = NSSize(width: 1240, height: 260)
        let savedSize = NSSize(
            width: sizeDefaults.double(forKey: widthKey),
            height: sizeDefaults.double(forKey: heightKey)
        )
        let initialSize = savedSize.width > 0 && savedSize.height > 0 ? savedSize : defaultSize
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 420, height: 130)
        panel.maxSize = NSSize(width: 3000, height: 1600)
        panel.ignoresMouseEvents = false
        panel.sharingType = .none

        hostingView = DraggableHostingView(rootView: OverlayCaptionView(captions: []))
        hostingView.onResize = { [sizeDefaults, widthKey, heightKey] size in
            sizeDefaults.set(size.width, forKey: widthKey)
            sizeDefaults.set(size.height, forKey: heightKey)
        }
        panel.contentView = hostingView
        panel.center()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func setAvailableForScreenCapture(_ isAvailable: Bool) {
        panel.sharingType = isAvailable ? .readOnly : .none
    }

    func append(id: UUID, originalText: String) {
        captions.append(.init(id: id, originalText: originalText))
        if captions.count > 500 {
            captions.removeFirst(captions.count - 500)
        }
        renderCaptions()
    }

    func setTranslation(id: UUID, text: String) {
        guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
        captions[index].russianText = text
        renderCaptions()
    }

    func clear() {
        captions.removeAll(keepingCapacity: true)
        renderCaptions()
    }

    private func renderCaptions() {
        hostingView.rootView = OverlayCaptionView(captions: captions)
    }
}

private final class DraggableHostingView: NSHostingView<OverlayCaptionView> {
    var onResize: ((NSSize) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }

        let localPoint = convert(event.locationInWindow, from: nil)
        if localPoint.x >= bounds.width - 20, localPoint.y <= 20 {
            resize(window: window)
            return
        }

        move(window: window)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(
            NSRect(x: max(0, bounds.width - 20), y: 0, width: 20, height: 20),
            cursor: .resizeUpDown
        )
    }

    private func move(window: NSWindow) {
        let initialLocation = NSEvent.mouseLocation
        let initialOrigin = window.frame.origin
        while let nextEvent = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if nextEvent.type == .leftMouseUp {
                break
            }
            let currentLocation = NSEvent.mouseLocation
            window.setFrameOrigin(.init(
                x: initialOrigin.x + currentLocation.x - initialLocation.x,
                y: initialOrigin.y + currentLocation.y - initialLocation.y
            ))
        }
    }

    private func resize(window: NSWindow) {
        let initialLocation = NSEvent.mouseLocation
        let initialFrame = window.frame
        while let nextEvent = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if nextEvent.type == .leftMouseUp {
                break
            }
            let currentLocation = NSEvent.mouseLocation
            let width = max(window.minSize.width, initialFrame.width + currentLocation.x - initialLocation.x)
            let height = max(window.minSize.height, initialFrame.height - currentLocation.y + initialLocation.y)
            let size = NSSize(
                width: min(width, window.maxSize.width),
                height: min(height, window.maxSize.height)
            )
            window.setFrame(
                NSRect(
                    x: initialFrame.minX,
                    y: initialFrame.maxY - size.height,
                    width: size.width,
                    height: size.height
                ),
                display: true
            )
            onResize?(size)
        }
    }
}

private struct OverlayCaption: Identifiable, Equatable {
    let id: UUID
    let originalText: String
    var russianText: String?
}

private struct OverlayCaptionView: View {
    let captions: [OverlayCaption]

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 1240, geometry.size.height / 260)
            let originalFontSize = min(44, max(16, 28 * scale))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: max(5, 8 * scale)) {
                        ForEach(captions) { caption in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(caption.originalText)
                                    .font(.system(size: originalFontSize, weight: .semibold))
                                    .foregroundStyle(.white)
                                if let russianText = caption.russianText,
                                   russianText != caption.originalText {
                                    Text(russianText)
                                        .font(.system(size: originalFontSize * 0.82, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.64))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("overlay-bottom")
                    }
                    .padding(max(6, 10 * scale))
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    proxy.scrollTo("overlay-bottom", anchor: .bottom)
                }
                .onChange(of: captions) { _, _ in
                    proxy.scrollTo("overlay-bottom", anchor: .bottom)
                }
            }
        }
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
        .padding(2)
        .help("Перетащите субтитры; потяните нижний правый угол для изменения размера")
    }
}
