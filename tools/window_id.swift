// Prints the id of the first on-screen window owned by the named process, for
// `screencapture -l` (see app_desktop/test_driver/shots_test.dart). Usage: swift window_id.swift ol1nplay_desktop
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? ""
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows where w[kCGWindowOwnerName as String] as? String == owner
    && w[kCGWindowLayer as String] as? Int == 0 {
    print(w[kCGWindowNumber as String] as? Int ?? 0)
    exit(0)
}
exit(1)
