import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Finder-style: transparent title bar, full-size content view so our
    // Flutter toolbar can sit flush with the traffic-light buttons.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = true
    // Use textured background so the title bar adapts to system appearance
    // (avoids a hard white seam when the app runs in dark mode).
    self.backgroundColor = NSColor.windowBackgroundColor

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
