import AppKit

let arguments = CommandLine.arguments
if arguments.count > 1, arguments[1] == "ctl" {
    exit(ControlCommand.runClient(Array(arguments.dropFirst(2))))
}

// A second launch just brings up the panel of the instance that is already running.
let bundleId = Bundle.main.bundleIdentifier ?? "com.yus100.grokspotlight"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty {
    _ = ControlCommand.runClient(["show"])
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
