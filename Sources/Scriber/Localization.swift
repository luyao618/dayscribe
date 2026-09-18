import Foundation

enum AppLanguage: String, Sendable, CaseIterable {
    case chinese = "zh-Hans"
    case english = "en"

    // Read once per launch. Locale also honors macOS per-app AppleLanguages.
    static let current = resolve(Locale.preferredLanguages)

    static func resolve(_ preferredLanguages: [String]) -> Self {
        let primary = preferredLanguages.first?.replacingOccurrences(of: "_", with: "-")
            .lowercased().split(separator: "-").first
        return primary == "en" ? .english : .chinese
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

enum L10n {
    struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
        let key: String
        let arguments: [String]

        init(stringLiteral value: String) { key = value; arguments = [] }
        init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []
            init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity)
                arguments.reserveCapacity(interpolationCount)
            }
            mutating func appendLiteral(_ literal: String) { key += literal }
            mutating func appendInterpolation<T>(_ value: T) {
                key += "{\(arguments.count)}"
                arguments.append(String(describing: value))
            }
        }
    }

    static let resourceBundle: Bundle = {
        #if SWIFT_PACKAGE
        // A distributed .app must resolve its own copy, not the build-machine path.
        if let url = Bundle.main.url(forResource: "Scriber_Scriber", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
        #else
        // Standalone developer tools compile Sources without SwiftPM's accessor.
        return Bundle.main
        #endif
    }()

    static func text(_ message: Message, language: AppLanguage = .current) -> String {
        let bundle = resourceBundle.url(forResource: language.rawValue, withExtension: "lproj")
            .flatMap(Bundle.init(url:))
        let template = bundle?.localizedString(forKey: message.key, value: message.key, table: "Localizable")
            ?? message.key
        return render(template, arguments: message.arguments)
    }

    private static let placeholders = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    /// Substitute the template once; a filename containing {1} or %@ stays literal.
    static func render(_ template: String, arguments: [String]) -> String {
        let source = template as NSString
        var output = ""
        var end = 0
        for match in placeholders.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: end, length: match.range.location - end))
            if let index = Int(source.substring(with: match.range(at: 1))), arguments.indices.contains(index) {
                output += arguments[index]
            } else { output += source.substring(with: match.range) }
            end = NSMaxRange(match.range)
        }
        return output + source.substring(from: end)
    }
}
