import SwiftUI
import AppKit

extension Color {
    /// Parse a hex color string (`#RRGGBB`, `RRGGBB`, `#RGB`, or `RGB`).
    /// Returns nil for any malformed input so callers can defensively
    /// fall back to a default. Used for persisting user-picked accent
    /// colors (e.g. per-speaker swatches) as JSON-friendly strings.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let scanner = Scanner(string: s)
        var v: UInt64 = 0
        guard scanner.scanHexInt64(&v) else { return nil }
        let r, g, b: Double
        switch s.count {
        case 3: // RGB
            r = Double((v >> 8) & 0xF) / 15.0
            g = Double((v >> 4) & 0xF) / 15.0
            b = Double(v & 0xF) / 15.0
        case 6: // RRGGBB
            r = Double((v >> 16) & 0xFF) / 255.0
            g = Double((v >> 8) & 0xFF) / 255.0
            b = Double(v & 0xFF) / 255.0
        default:
            return nil
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// Encode the color as `#RRGGBB`. Returns nil if the color can't be
    /// resolved into sRGB components (very rare; named/system colors).
    func toHex() -> String? {
        let ns = NSColor(self).usingColorSpace(.sRGB)
        guard let ns else { return nil }
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
