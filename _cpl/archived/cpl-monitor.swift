import AppKit
import CoreGraphics
import Darwin

guard CommandLine.arguments.count > 1 else { exit(1) }
let project = CommandLine.arguments[1]

func windowOnScreen() -> Bool {
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    return windowList.contains { info in
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        let name = info[kCGWindowName as String] as? String ?? ""
        return owner.hasPrefix("iTerm") && name.contains(project)
    }
}

// Wait for window to appear (up to 10s)
var appeared = false
for _ in 0..<20 {
    if windowOnScreen() {
        appeared = true
        break
    }
    usleep(500_000)
}
guard appeared else { exit(1) }

// Poll until window disappears from screen
while windowOnScreen() {
    usleep(500_000)
}

// Window gone — close Zed
let home = FileManager.default.homeDirectoryForCurrentUser.path
let task = Process()
task.executableURL = URL(fileURLWithPath: "\(home)/bin/cpl-close-zed")
task.arguments = [project]
try? task.run()
task.waitUntilExit()
