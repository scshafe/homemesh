import SwiftUI
import UIKit

// Shared-candidate pieces (tokens, status tones, notes and chips). Everything in Sui/ is written so it can move to the
// scshafe-ios package unchanged: no app types, nothing from outside this folder. Appearance follows the system.

extension Color {
    /// A colour that is `light` in the light appearance and `dark` in the dark one.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

enum SuiColor {
    /// The brand accent (scshafe-ui 0.9.0): #0a4f99 in light, #6cb6ff in dark. The AccentColor asset carries the same pair.
    static let accent = Color(light: 0x0a4f99, dark: 0x6cb6ff)
    static let success = Color(light: 0x1a7f37, dark: 0x4cc38a)
    static let warning = Color(light: 0x9a5b00, dark: 0xf0b44c)
    static let danger = Color(light: 0xc62828, dark: 0xff7b72)
    static let neutral = Color.secondary
}

/// What a status means. Never shown by colour alone: each tone has its symbol and the text says it too.
enum SuiTone: CaseIterable, Sendable {
    case info, success, warning, danger, neutral

    var color: Color {
        switch self {
        case .info: SuiColor.accent
        case .success: SuiColor.success
        case .warning: SuiColor.warning
        case .danger: SuiColor.danger
        case .neutral: SuiColor.neutral
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .neutral: "minus.circle.fill"
        }
    }
}

extension SuiTone {
    /// Done is success, outstanding is a warning.
    static func tone(complete: Bool) -> SuiTone { complete ? .success : .warning }
}

/// A footnote with its tone's symbol: a hint, a warning, a problem.
struct SuiNote: View {
    let tone: SuiTone
    let text: String
    init(_ tone: SuiTone, _ text: String) { self.tone = tone; self.text = text }

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: tone.symbol) }
            .font(.footnote)
            .foregroundStyle(tone.color)
    }
}

/// A small capsule: the tone's symbol and a short label.
struct SuiChip: View {
    let tone: SuiTone
    let text: String
    init(_ tone: SuiTone, _ text: String) { self.tone = tone; self.text = text }

    var body: some View {
        Label(text, systemImage: tone.symbol)
            .font(.caption2)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tone.color.opacity(0.15), in: Capsule())
    }
}

/// Colours of things drawn on a plan or in 3D. They are about what a thing is, not how it is doing, so they are not tones;
/// each pair reads on the light and the dark canvas, and `outline` replaces the black strokes that vanished in dark mode.
enum SuiPlanColor {
    static let outline = Color(light: 0x1c1c1e, dark: 0xf2f2f7)
    static let onMarker = Color(light: 0x1c1c1e, dark: 0x1c1c1e)
    static let movable = Color(light: 0xb25e00, dark: 0xffa94d)
    static let fixed = Color(light: 0x7a5230, dark: 0xc9a27a)
    static let stair = Color(light: 0x7b3fa0, dark: 0xc79bf0)
    static let window = Color(light: 0x00768f, dark: 0x5ccfe6)
    static let opening = movable
    static let measurement = Color(light: 0xc2185b, dark: 0xff80ab)
    static let draft = measurement
    static let outlet = Color(light: 0xd4a017, dark: 0xffd54f)
    static let jack = SuiColor.success
    static let accessPoint = SuiColor.accent
    static let roomTint = SuiColor.accent
    static let allow = SuiColor.success
    static let forbid = SuiColor.danger
    static let prefer = SuiColor.warning
    static let doorMarker = Color(light: 0xe08a00, dark: 0xffb340)
}
