import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// The Aurora colors. The field colors are kept dim enough that `upcoming`
/// text stays at 4.5:1 contrast or better wherever a field drifts behind it.
enum Palette {
    static let navy = Color(hex: 0x0A1C4A)
    static let past = Color(hex: 0x4F74B5)
    static let upcoming = Color(hex: 0x9FC2FF)
    static let glow = Color(hex: 0x8FB8FF)
    static let fieldBlue = Color(hex: 0x1D3B9F)
    static let fieldViolet = Color(hex: 0x44259A)
    static let fieldTeal = Color(hex: 0x0C4A70)
    static let bookmarkTick = Color(hex: 0x6FF5CF)
    /// The dark wash behind the control bar and side panel.
    static let scrim = Color(hex: 0x071538)
}
