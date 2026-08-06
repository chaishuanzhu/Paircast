import Foundation

/// Kodi-style metadata sidecars next to the movie object.
/// `films/Foo.2010.mkv` → `Foo.2010.nfo` / `Foo.2010-poster.jpg` / `Foo.2010-fanart.jpg`
public enum MovieMetadataObjectKey {
    public static func movieBase(from movieObjectKey: String) -> String? {
        let key = movieObjectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.hasPrefix("_tandem/") else { return nil }
        let base = (key as NSString).deletingPathExtension
        return base.isEmpty ? nil : base
    }

    public static func nfoKey(for movieObjectKey: String) -> String? {
        movieBase(from: movieObjectKey).map { "\($0).nfo" }
    }

    public static func posterKey(for movieObjectKey: String) -> String? {
        movieBase(from: movieObjectKey).map { "\($0)-poster.jpg" }
    }

    public static func fanartKey(for movieObjectKey: String) -> String? {
        movieBase(from: movieObjectKey).map { "\($0)-fanart.jpg" }
    }

    public static func isNFO(_ objectKey: String) -> Bool {
        (objectKey as NSString).pathExtension.lowercased() == "nfo"
    }
}
