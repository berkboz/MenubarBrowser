// Prints the window number of Perch's panel, for `screencapture -l`.
import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    guard window[kCGWindowOwnerName as String] as? String == "Perch",
          window[kCGWindowLayer as String] as? Int == 3, // .floating
          let number = window[kCGWindowNumber as String] as? Int else { continue }
    print(number)
    break
}
