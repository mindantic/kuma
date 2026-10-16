import AppKit

enum MenuBarIcon {
    private static let side: CGFloat = 18

    private static let glyph: NSImage? = {
        if let url = ResourceLocator.asset("MenuBarGlyph.png"), let image = NSImage(contentsOf: url) {
            if let retina = ResourceLocator.asset("MenuBarGlyph@2x.png"), let rep = NSImageRep(contentsOf: retina) {
                rep.size = NSSize(width: side, height: side)
                image.addRepresentation(rep)
            }
            image.size = NSSize(width: side, height: side)
            return image
        }
        if let url = ResourceLocator.asset("menubar-glyph.png"), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: side, height: side)
            return image
        }
        return NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Kuma")
    }()

    private static var cache: [String: NSImage] = [:]

    static func image(attention: Bool, dimmed: Bool) -> NSImage {
        let key = "\(attention)-\(dimmed)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            glyph?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.35 : 1)
            guard attention else { return true }
            let dot = NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = attention ? "Kuma, something needs you" : "Kuma"
        cache[key] = image
        return image
    }
}
