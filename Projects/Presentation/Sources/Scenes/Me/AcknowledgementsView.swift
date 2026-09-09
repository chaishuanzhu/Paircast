import SwiftUI

/// Third-party notices required for App Store (VLCKit is LGPL).
public struct AcknowledgementsView: View {
    public init() {}

    public var body: some View {
        List {
            Section("播放") {
                Text("VLCKit / MobileVLCKit（VideoLAN，LGPLv2.1+）以动态框架链接。完整许可见 VideoLAN 网站。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("即时通讯") {
                Text("腾讯云 IM SDK。使用受腾讯云服务协议约束。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("字幕与元数据") {
                Text("在线字幕检索使用 OpenSubtitles API（需你自己的 Key）。可选的封面补全使用 OMDb（需你自己的 Key）。本应用不抓取豆瓣或 IMDb。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("隐私") {
                Link("隐私政策", destination: URL(string: "https://chai-sz.github.io/tandem/privacy")!)
                Link("支持与举报", destination: URL(string: "https://chai-sz.github.io/tandem/support")!)
            }
        }
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}
