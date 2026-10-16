import AppKit
import Combine
import KumaCore
import SwiftUI

final class PawPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 500, height: 110), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PawBubbleController {
    private let model: AppModel
    private let panel = PawPanel()
    private var cancellables: Set<AnyCancellable> = []
    private var hosting: FirstMouseHostingView<PawBubbleView>?
    private var visible = false

    init(model: AppModel) {
        self.model = model
        model.$current
            .combineLatest(model.$pendingCount)
            .receive(on: RunLoop.main)
            .sink { [weak self] current, pending in self?.render(current, pending: pending) }
            .store(in: &cancellables)
    }

    private func render(_ briefing: Briefing?, pending: Int) {
        guard let briefing else {
            hide()
            return
        }
        let view = PawBubbleView(briefing: briefing, pendingCount: pending, onSkip: { [weak model] in model?.skipCurrent() }, onClear: { [weak model] in model?.clearAll() })
        if let hosting {
            hosting.rootView = view
        } else {
            let created = FirstMouseHostingView(rootView: view)
            created.sizingOptions = [.intrinsicContentSize]
            panel.contentView = created
            hosting = created
        }
        show()
    }

    private func show() {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let frame = screenWithMouse().visibleFrame
        let origin = NSPoint(x: (frame.midX - size.width / 2).rounded(), y: frame.minY + 18)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        guard !visible else { return }
        visible = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.visible else { return }
            self.panel.orderOut(nil)
        })
    }

    private func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

struct PawBubbleView: View {
    static let appIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "app-icon", withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        return NSApp.applicationIconImage
    }()

    let briefing: Briefing
    let pendingCount: Int
    let onSkip: () -> Void
    let onClear: () -> Void
    @State private var hoveringClear = false
    @State private var pulse = false

    var body: some View {
        content(briefing)
            .padding(14)
    }

    private func content(_ briefing: Briefing) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(KumaTheme.purple.opacity(0.5), lineWidth: 2)
                    .frame(width: 44, height: 44)
                    .scaleEffect(pulse ? 1.22 : 1)
                    .opacity(pulse ? 0 : 1)
                Image(nsImage: PawBubbleView.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(briefing.project)
                        .font(.system(size: 12, weight: .semibold))
                    Text(briefing.tool == .other ? "Kuma" : briefing.tool.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if briefing.priority == .high {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                    }
                    if pendingCount > 0 {
                        Text("+\(pendingCount) more")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(KumaTheme.purple.opacity(0.18)))
                            .foregroundStyle(KumaTheme.purple)
                    }
                }
                Text(briefing.text)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 36)
        .padding(.vertical, 16)
        .frame(minWidth: 320, maxWidth: 500, alignment: .leading)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thickMaterial)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(KumaTheme.purple.opacity(0.35), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button {
                onClear()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(hoveringClear ? 0.15 : 0.07)))
            }
            .buttonStyle(.plain)
            .onHover { hoveringClear = $0 }
            .help("Clear all briefings")
            .padding(10)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { onSkip() }
        .help("Click to skip, Option Esc also skips")
        .onAppear {
            pulse = false
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}
