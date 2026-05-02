import CoreGraphics
import SwiftUI

/// Vectorised Cutti brand logo — eyebrows, eyes and the little nose hook
/// underneath — rendered from the authoritative SVG path so there is a
/// single source of truth for geometry. The raw `d` attribute is copied
/// verbatim from `cutti-logo.svg` (viewBox `0 0 1064 1094`) and parsed at
/// first use into five independent `SwiftUI.Path` subpaths, matching the
/// five `M … Z` groups in the SVG (right brow, left brow, left eye, right
/// eye, nose — in source order).
///
/// The parser intentionally only supports `M`, `C` and `Z` because the
/// source path uses nothing else. Any other command would indicate the
/// asset was regenerated with a different exporter and we want that to
/// fail loudly rather than silently drop strokes.
enum CuttiLogoPathData {
    /// SVG coordinate system the raw path is authored in.
    static let viewBox = CGSize(width: 1064, height: 1094)

    /// Stable indices into ``subpaths`` — mirror the `M … Z` order in the
    /// source SVG. Callers reference parts by name to keep the mapping
    /// from "visual component" to "subpath" explicit at every call site.
    enum Part: Int, CaseIterable {
        case rightBrow = 0
        case leftBrow  = 1
        case leftEye   = 2
        case rightEye  = 3
        case nose      = 4
    }

    /// Raw SVG `d` attribute copied verbatim from `cutti-logo.svg`. Do
    /// not hand-edit — regenerate from the source asset if the logo
    /// changes.
    static let rawPathData: String = """
    M888.858 0.62487C874.617 1.78587 865.299 3.81485 847.014 9.73485C812.493 20.9129 790.996 33.1559 770.39 53.3749C757.145 66.3709 748.913 78.2509 737.715 100.526C723.74 128.327 721.374 136.075 721.36 154.094C721.352 164.149 721.687 166.823 723.429 170.594C726.181 176.552 728.707 179.028 734.154 181.108C739.47 183.139 744.005 182.585 748.802 179.32C755.567 174.715 756.197 172.948 756.836 156.772C757.478 140.509 758.252 137.81 767.638 119.094C781.918 90.6219 793.789 76.3119 814.256 62.8969C828.68 53.4429 856.922 42.0699 876.001 38.0339C884.915 36.1469 921.301 34.1869 932.391 34.9949C952.514 36.4619 966.262 44.9249 986.97 68.5939C1003 86.9189 1015.67 106.76 1025.83 129.485C1031.19 141.453 1034.63 146.228 1039.35 148.197C1047.84 151.745 1057.83 148.205 1061.66 140.292C1065.25 132.878 1064.56 128.76 1057.01 112.594C1034.69 64.7929 1000.96 24.8479 969.256 8.68487C955.273 1.55587 948.671 0.341878 922.256 0.0398781C909.606 -0.105122 894.577 0.15787 888.858 0.62487ZM188.756 27.1879C170.264 28.4529 149.693 32.0309 138.001 36.0149C116.821 43.2309 88.8607 60.8749 70.0217 78.9119C55.3877 92.9229 34.5087 118.696 24.5077 135.094C21.4887 140.044 16.4506 148.144 13.3136 153.094C1.72664 171.371 -0.802369 180.241 0.199631 199.094C0.966631 213.547 2.68269 219.445 7.29869 223.498C15.5697 230.76 29.4966 227.981 34.1676 218.138C35.5036 215.323 35.9026 211.243 36.0586 198.803L36.2557 183.036L43.6587 171.065C47.7307 164.481 53.1307 155.769 55.6587 151.706C62.9027 140.064 83.5017 115.017 94.5177 104.457C100.393 98.8249 109.658 91.4199 116.811 86.6389C147.34 66.2319 165.05 62.0419 217.256 62.8769C248.02 63.3689 250.063 63.6299 267.256 69.2649C278.627 72.9919 289.848 78.4449 300.266 85.3079C314.663 94.7899 317.789 99.0818 335.341 133.468C341.214 144.974 346.687 154.343 348.818 156.539C357.571 165.558 371.185 163.514 376.894 152.323C380.505 145.246 379.48 141.906 365.325 114.633C350.472 86.0159 345.698 78.4609 336.788 69.4749C326.798 59.3999 306.491 46.7629 288.256 39.2739C266.966 30.5309 250.31 27.6509 218.256 27.1709C205.056 26.9729 191.781 26.9799 188.756 27.1879ZM214.256 338.922C208.095 341.338 204.966 343.629 198.695 350.317C141.984 410.8 129.563 673.108 176.908 810.414C188.544 844.16 203.568 867.094 218.454 873.835C225.013 876.805 233.549 876.744 240.489 873.676C247.268 870.679 257.639 859.754 264.022 848.885C297.559 791.777 312.778 650.608 299.198 522.594C293.194 465.996 280.814 413.143 265.809 380.05C256.819 360.224 243.17 343.763 232.369 339.722C226.16 337.399 218.953 337.081 214.256 338.922ZM853.256 339.922C847.256 342.275 844.14 344.514 838.202 350.744C811.396 378.864 793.071 451.487 787.649 551.094C786.374 574.512 787.001 637.702 788.725 659.594C796.897 763.349 817.785 838.18 846.19 865.455C854.216 873.162 860.169 876.01 868.256 876.01C876.049 876.01 882.101 873.26 889.411 866.4C916.413 841.058 935.409 770.612 941.807 672.094C943.251 649.855 943.24 591.162 941.787 567.094C933.636 432.094 900.357 338.034 860.968 338.67C858.377 338.712 854.906 339.275 853.256 339.922ZM563.411 868.007C555.881 870.781 551.756 876.771 551.756 884.933C551.756 888.555 552.865 891.189 558.006 899.771C561.444 905.51 565.022 911.755 565.959 913.65C566.896 915.544 568.975 919.794 570.58 923.094C572.184 926.394 578.946 939.793 585.606 952.87C599.509 980.171 601.485 985.86 608.741 1019.48C611.517 1032.35 614.039 1043.87 614.345 1045.09C614.9 1047.3 614.89 1047.31 595.078 1048C570.606 1048.86 559.797 1050.5 543.892 1055.79C534.186 1059.02 530.69 1060.69 527.735 1063.5C517.017 1073.71 522.561 1090.78 537.361 1093.15C540.433 1093.64 543.469 1093.07 550.315 1090.72C568.114 1084.6 569.639 1084.41 606.256 1083.7C642.775 1082.99 644.739 1082.71 650.621 1077.3C652.562 1072.35 657.251 1063.25 653.696 1054.95C652.562 1052.31 648.967 1037.98 645.706 1023.12C633.487 967.419 635.278 972.241 604.465 912.094C603.056 909.344 599.804 902.819 597.239 897.594C590.669 884.212 582.492 872.226 578.209 869.699C573.46 866.897 568.092 866.283 563.411 868.007Z
    """

    /// Parsed subpaths in SVG coordinate space. Force-unwrapping the
    /// parse result is deliberate: the raw string is a compile-time
    /// asset, so any parse failure is a programmer error that must
    /// surface immediately in development and tests, not at runtime for
    /// end users. ``CuttiLogoShapeTests`` asserts this succeeds on every
    /// build.
    static let subpaths: [Path] = {
        do {
            let parsed = try SVGPathParser.parseSubpaths(rawPathData)
            precondition(
                parsed.count == Part.allCases.count,
                "Cutti logo must parse into \(Part.allCases.count) subpaths, got \(parsed.count)"
            )
            return parsed
        } catch {
            preconditionFailure("Cutti logo SVG path failed to parse: \(error)")
        }
    }()

    /// Tight curve bounding rectangles (in SVG coordinate space) for
    /// each sub-path, computed once from the parsed ``subpaths``. Uses
    /// `CGPath.boundingBoxOfPath` rather than `Path.boundingRect` so
    /// the result reflects the rendered curve bounds instead of the
    /// looser control-point hull — important for anchoring the blink
    /// around the eye's *visual* centre.
    static let boundingBoxes: [CGRect] = subpaths.map { $0.cgPath.boundingBoxOfPath }

    static func boundingBox(of part: Part) -> CGRect {
        boundingBoxes[part.rawValue]
    }

    /// Anchor point (in unit coordinates of the full SVG viewBox) at
    /// which `part`'s visual centre lies. Feed this into
    /// `scaleEffect(anchor:)` so eyelid closure pivots around the eye's
    /// geometric centre instead of the logo's centre.
    static func anchor(of part: Part) -> UnitPoint {
        let bbox = boundingBox(of: part)
        return UnitPoint(
            x: bbox.midX / viewBox.width,
            y: bbox.midY / viewBox.height
        )
    }
}

// MARK: - SVG path parser (M / C / Z only)

enum SVGPathParserError: Error, CustomStringConvertible {
    case unsupportedCommand(Character, index: Int)
    case missingNumber(expectedAfter: Character, index: Int)
    case invalidNumber(String, index: Int)
    case trailingGarbage(index: Int)
    case emptyPath

    var description: String {
        switch self {
        case .unsupportedCommand(let c, let i):
            return "Unsupported SVG path command '\(c)' at index \(i); parser only accepts M, C, Z."
        case .missingNumber(let after, let i):
            return "Expected number after command '\(after)' at index \(i)."
        case .invalidNumber(let s, let i):
            return "Could not parse number '\(s)' at index \(i)."
        case .trailingGarbage(let i):
            return "Unexpected trailing data at index \(i)."
        case .emptyPath:
            return "SVG path data was empty."
        }
    }
}

/// Minimal SVG path `d` attribute parser. Supports the absolute
/// commands actually used by the Cutti logo asset:
/// * `M x y`             — moveto
/// * `L x y`             — lineto (repeated coord pairs without
///                        re-emitting the letter are allowed)
/// * `C x1 y1 x2 y2 x y` — cubic Bézier curveto (and repeated coord
///                        groups without re-emitting the letter)
/// * `Z` / `z`           — closepath
///
/// Anything else raises ``SVGPathParserError`` so a regenerated asset
/// with new commands fails at test time rather than silently dropping
/// geometry.
enum SVGPathParser {
    /// Parses the given SVG `d` string and returns one ``Path`` per
    /// top-level subpath (each `M` starts a new one).
    static func parseSubpaths(_ d: String) throws -> [Path] {
        let scalars = Array(d.unicodeScalars)
        guard !scalars.isEmpty else { throw SVGPathParserError.emptyPath }

        var paths: [Path] = []
        var current = Path()
        var hasCurrent = false
        var i = 0

        func skipSeparators() {
            while i < scalars.count {
                let s = scalars[i]
                if s == " " || s == "\t" || s == "\n" || s == "\r" || s == "," {
                    i += 1
                } else {
                    break
                }
            }
        }

        func readNumber(after command: Character) throws -> CGFloat {
            skipSeparators()
            let start = i
            // Optional sign
            if i < scalars.count, scalars[i] == "-" || scalars[i] == "+" {
                i += 1
            }
            var sawDigit = false
            while i < scalars.count, scalars[i].isAsciiDigit {
                i += 1
                sawDigit = true
            }
            if i < scalars.count, scalars[i] == "." {
                i += 1
                while i < scalars.count, scalars[i].isAsciiDigit {
                    i += 1
                    sawDigit = true
                }
            }
            if i < scalars.count, scalars[i] == "e" || scalars[i] == "E" {
                i += 1
                if i < scalars.count, scalars[i] == "-" || scalars[i] == "+" {
                    i += 1
                }
                while i < scalars.count, scalars[i].isAsciiDigit {
                    i += 1
                }
            }
            guard sawDigit else {
                throw SVGPathParserError.missingNumber(expectedAfter: command, index: start)
            }
            let slice = String(String.UnicodeScalarView(scalars[start..<i]))
            guard let value = Double(slice) else {
                throw SVGPathParserError.invalidNumber(slice, index: start)
            }
            return CGFloat(value)
        }

        func peekIsNumberStart() -> Bool {
            skipSeparators()
            guard i < scalars.count else { return false }
            let s = scalars[i]
            if s == "-" || s == "+" || s == "." { return true }
            return s.isAsciiDigit
        }

        skipSeparators()
        while i < scalars.count {
            let scalar = scalars[i]
            guard let command = Character(String(scalar)).asSVGCommand else {
                throw SVGPathParserError.unsupportedCommand(Character(String(scalar)), index: i)
            }
            i += 1
            switch command {
            case "M":
                if hasCurrent {
                    paths.append(current)
                    current = Path()
                }
                hasCurrent = true
                let x = try readNumber(after: "M")
                let y = try readNumber(after: "M")
                current.move(to: CGPoint(x: x, y: y))
            case "C":
                repeat {
                    let c1x = try readNumber(after: "C")
                    let c1y = try readNumber(after: "C")
                    let c2x = try readNumber(after: "C")
                    let c2y = try readNumber(after: "C")
                    let ex  = try readNumber(after: "C")
                    let ey  = try readNumber(after: "C")
                    current.addCurve(
                        to: CGPoint(x: ex, y: ey),
                        control1: CGPoint(x: c1x, y: c1y),
                        control2: CGPoint(x: c2x, y: c2y)
                    )
                } while peekIsNumberStart()
            case "L":
                repeat {
                    let x = try readNumber(after: "L")
                    let y = try readNumber(after: "L")
                    current.addLine(to: CGPoint(x: x, y: y))
                } while peekIsNumberStart()
            case "Z":
                current.closeSubpath()
            default:
                throw SVGPathParserError.unsupportedCommand(command, index: i - 1)
            }
            skipSeparators()
        }

        if hasCurrent {
            paths.append(current)
        }
        return paths
    }
}

// MARK: - small scalar helpers

private extension Unicode.Scalar {
    var isAsciiDigit: Bool { self >= "0" && self <= "9" }
}

private extension Character {
    /// Accepts only the SVG path commands this parser supports. Lower
    /// and upper case `z` both close a subpath (SVG treats them
    /// identically); everything else returns `nil` so the parser can
    /// emit a precise diagnostic.
    var asSVGCommand: Character? {
        switch self {
        case "M", "C", "L", "Z": return self
        case "m": return "M"
        case "c": return "C"
        case "l": return "L"
        case "z": return "Z"
        default:  return nil
        }
    }
}

// MARK: - Shape

/// Draws a chosen subset of the Cutti logo subpaths scaled to fit
/// `rect`. The full logo aspect ratio must be preserved by the caller
/// (pass a frame matching ``CuttiLogoPathData/viewBox``) — this shape
/// scales X and Y independently because SwiftUI's layout system, not
/// the shape, owns aspect-ratio preservation.
struct CuttiLogoPartsShape: Shape {
    let parts: [CuttiLogoPathData.Part]

    func path(in rect: CGRect) -> Path {
        let viewBox = CuttiLogoPathData.viewBox
        let sx = rect.width  / viewBox.width
        let sy = rect.height / viewBox.height
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: sx, y: sy)
        var combined = Path()
        for part in parts {
            combined.addPath(CuttiLogoPathData.subpaths[part.rawValue], transform: transform)
        }
        return combined
    }
}
