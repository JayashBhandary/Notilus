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

    // Enforce a minimum size so the 3-pane Finder-style layout always has
    // enough room (sidebar + file area + right panel).
    self.contentMinSize = NSSize(width: 900, height: 600)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
