import SwiftUI

/// Third-party notices required for App Store (VLCKit is LGPL).
public struct AcknowledgementsView: View {
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
                Text("Online subtitle search uses the OpenSubtitles API (requires your own key). Optional poster enrichment uses OMDb (requires your own key). This app does not scrape Douban or IMDb.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Link("Privacy Policy", destination: URL(string: "https://blog.chaisz.com/Paircast/privacy/")!)
                Link("Support & Reports", destination: URL(string: "https://blog.chaisz.com/Paircast/support/")!)
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
