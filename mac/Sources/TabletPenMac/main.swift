import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
if CommandLine.arguments.contains("--selftest") {
    let d = SelfTest()
    app.delegate = d
    app.setActivationPolicy(.regular)
    app.run()
} else {
    let d = AppDelegate()
    app.delegate = d
    app.setActivationPolicy(.accessory)
    app.run()
}
