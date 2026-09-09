import Foundation

/// Named placeholders in localization templates, e.g. `"Host is now {{name}}"`.
public enum StringTemplate {
    public static func apply(_ template: String, _ args: [String: String]) -> String {
        guard !args.isEmpty else { return template }
        var result = template
        for (key, value) in args {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
}
