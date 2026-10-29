import AppKit

// Writing to the agent's stdin after it exits must fail the write, not kill Wisp with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

// The test host links this executable. Its process name contains one of these; the app binary is `Wisp`.
let runningUnderTests = {
    let name = ProcessInfo.processInfo.processName
    return name.contains("xctest") || name.contains("PackageTests")
}()

if !runningUnderTests {
    launch()
}

private func launch() {
    let arguments = CommandLine.arguments
    if arguments.count > 1, arguments[1] == "ctl" {
        exit(ControlClient.run(Array(arguments.dropFirst(2))))
    }
    if arguments.count > 2, arguments[1] == "render-screenshots" {
        exit(MainActor.assumeIsolated { Screenshots.render(into: URL(filePath: arguments[2])) })
    }

    // Running the binary again shows the panel of the copy already running. (Opening the app from Finder
    // or `open` never starts a second copy; the running one gets a reopen event instead.)
    let bundleID = Bundle.main.bundleIdentifier ?? "com.yus100.wisp"
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty {
        exit(ControlClient.run(["show"]))
    }

    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = MainMenu.make()
        withExtendedLifetime(delegate) { app.run() }
    }
}
