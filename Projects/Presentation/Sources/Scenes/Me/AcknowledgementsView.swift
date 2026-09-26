import SwiftUI

/// Third-party notices required for App Store (VLCKit is LGPL).
public struct AcknowledgementsView: View {
    @Environment(\.locale) private var locale

    public init() {}

    public var body: some View {
        List {
            Section("Playback") {
                Text("VLCKit / MobileVLCKit (VideoLAN, LGPLv2.1+) is linked as a dynamic framework. Full license text is available on the VideoLAN website.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Messaging") {
                Text("Tencent Cloud IM SDK. Use is subject to Tencent Cloud service agreements.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Subtitles & Metadata") {
                Text("Online subtitle search uses the OpenSubtitles API (requires your own key). Movie metadata uses TMDB (requires your own token). This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Emoji") {
                Text("Chat emoji art uses Twemoji graphics by Twitter, Inc and contributors, licensed under CC-BY 4.0.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("Twemoji on GitHub", destination: URL(string: "https://github.com/twitter/twemoji")!)
            }
            Section("Images") {
                Text("Network images (posters, avatars, stickers, Twemoji CDN) are loaded and cached with Kingfisher (MIT), including original files on disk.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("Kingfisher on GitHub", destination: URL(string: "https://github.com/onevcat/Kingfisher")!)
            }
            Section("Privacy") {
                Link("Privacy Policy", destination: privacyURL)
                Link("Support & Reports", destination: supportURL)
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var docsLocalePath: String {
        if locale.identifier.hasPrefix("zh") {
            return "zh-Hans"
        }
        return "en-US"
    }

    private var privacyURL: URL {
        URL(string: "https://paircast.chaisz.com/\(docsLocalePath)/privacy/")!
    }

    private var supportURL: URL {
        URL(string: "https://paircast.chaisz.com/\(docsLocalePath)/support/")!
    }
}
