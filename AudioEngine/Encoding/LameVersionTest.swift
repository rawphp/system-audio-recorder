import Foundation
import lame

/// Minimal bridge into LAME used to verify that `lame.xcframework` is correctly
/// vendored and linked. REQ-017 (`LameEncoder`) will replace this with the real
/// encoder; until then, `LameProbe.version` provides build- and runtime-time
/// evidence that the C symbols are reachable.
enum LameProbe {
    static let version: String = String(cString: get_lame_version())
}
