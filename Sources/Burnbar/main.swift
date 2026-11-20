import AppKit

let app = NSApplication.shared

// `Burnbar --render-icon <dir.iconset>` writes the app icon PNGs (used by install.sh).
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), CommandLine.arguments.indices.contains(i + 1) {
    do { try AppIcon.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])); exit(0) }
    catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
}

let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
