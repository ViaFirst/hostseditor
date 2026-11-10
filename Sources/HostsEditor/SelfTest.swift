import AppKit
import SwiftUI

/// Command-line self-tests, so the app can be verified without clicking it:
///   HostsEditor --self-test             logic checks, PASS/FAIL lines, exit 1 on failure
///   HostsEditor --render-test <out.png> renders the main view into a PNG
@MainActor
enum SelfTest {
    /// Returns true when a test needs the run loop (it calls exit() itself when done).
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--self-test") { selfTest() }
        if let i = args.firstIndex(of: "--render-test"), i + 1 < args.count {
            renderTest(out: args[i + 1])
            return true
        }
        return false
    }

    private static func check(_ ok: Bool, _ message: String) {
        print(ok ? "PASS" : "FAIL", message)
        if !ok { exit(1) }
    }

    private static func selfTest() {
        check(Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier == "com.viafirst.hostseditor", "bundle id")
        let model = AppModel()
        model.counter += 1
        check(model.counter == 1, "model updates")
        exit(0)
    }

    /// SwiftUI draws text and controls in layers that `cacheDisplay` misses: show the view in a real
    /// window (below the desktop, unseen), let it render, then draw its layer tree at 2x.
    private static func renderTest(out: String) {
        let size = CGSize(width: 520, height: 360)
        let view = NSHostingView(rootView: ContentView(model: AppModel()))
        view.sizingOptions = []   // keep the window size instead of shrinking to the content
        let window = NSWindow(contentRect: CGRect(origin: NSScreen.screens.first?.frame.origin ?? .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            let scale: CGFloat = 2
            guard let layer = view.layer,
                  let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { exit(1) }
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
            ctx.scaleBy(x: scale, y: scale)
            // The hosting view's layer tree is top-left based; CG contexts are bottom-left.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            layer.render(in: ctx)
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("wrote", out)
            exit(0)
        }
    }
}
