import CoreText
import SwiftUI

enum InkspringTypography {
    private enum Family: String {
        case newsreader = "Newsreader"
        case geist = "Geist"

        var postScriptName: String {
            switch self {
            case .newsreader: "Newsreader16pt16pt-Regular"
            case .geist: "Geist-Regular"
            }
        }
    }

    private static let registeredFonts = Set([Family.newsreader, .geist].filter { family in
        guard let url = Bundle.main.url(forResource: family.rawValue, withExtension: "ttf", subdirectory: "Fonts") else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    })

    static func registerFonts() {
        _ = registeredFonts
    }

    static func editorial(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        registeredFonts.contains(.newsreader)
            ? .custom(Family.newsreader.postScriptName, size: size, relativeTo: style)
            : .system(size: size, design: .serif)
    }

    static func editorialCapHeight(_ size: CGFloat) -> CGFloat {
        let name = registeredFonts.contains(.newsreader) ? Family.newsreader.postScriptName : "Times-Roman"
        return CTFontGetCapHeight(CTFontCreateWithName(name as CFString, size, nil))
    }

    static func interface(_ size: CGFloat) -> Font {
        registeredFonts.contains(.geist)
            ? .custom(Family.geist.postScriptName, size: size, relativeTo: .body)
            : .system(size: size)
    }
}
