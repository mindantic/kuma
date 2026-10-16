import AppKit
import Combine
import KumaCore
import SwiftUI

@main
struct KumaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("Kuma Dashboard", id: KumaWindowID.dashboard) {
            DashboardView(model: delegate.model)
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    let model = AppModel()
    private var bubble: PawBubbleController?
    private var hotKey: SkipHotKey?
    private var cancellables: Set<AnyCancellable> = []
    private var launchActionsDone = false

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !SingleInstance.claim() { SingleInstance.handOffAndExit() }
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        bubble = PawBubbleController(model: model)
        let hotKey = SkipHotKey { [weak self] in self?.model.skipCurrent() }
        self.hotKey = hotKey
        model.$current
            .map { $0 != nil }
            .removeDuplicates()
            .combineLatest(model.$skipShortcut.removeDuplicates())
            .sink { active, key in hotKey.update(active: active, key: key) }
            .store(in: &cancellables)
        SingleInstance.observe { [weak self] in self?.model.openDashboard() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func labelDidAppear() {
        guard !launchActionsDone else { return }
        launchActionsDone = true
        let args = CommandLine.arguments
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [model] in
            if args.contains("--dashboard") { model.openDashboard() }
            if args.contains("--settings") { model.openSettings() }
            if args.contains("--demo"), model.useMockData { model.mockStartDemoBriefings() }
            if args.contains("--menu") { AppDelegate.shared?.showMenuPreview() }
        }
    }

    private var menuPreview: NSWindow?

    private func showMenuPreview() {
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: MenuBarView(model: model))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        effect.frame = hosting.frame
        effect.addSubview(hosting)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView = effect
        window.title = "Menu preview"
        window.center()
        window.makeKeyAndOrderFront(nil)
        menuPreview = window
    }

}
