import Foundation

public enum AppError: Error, Equatable, Sendable {
    case notConfigured
    case incompleteConfig(missing: [String])
    case invalidCredentials
    case accountUnavailable
    case imInitFailed
    case network
    case userSigExpired
    case kickedOffline
    case invalidConfigQR
    case configQRTooLarge
    case catalogUnauthorized
    case playbackFailed
    case unsupportedContainer
    case movieChangeFailed
    case onlyHostCanSwitchMovie
    case roomEnded
    case roomNotFound
    case subtitleUnavailable
    case validation(String)
    case unknown(String)

    public var userMessage: String {
        switch self {
        case .notConfigured:
            return "请先完成服务配置"
        case .incompleteConfig(let missing):
            return "配置不完整：\(missing.joined(separator: "、"))"
        case .invalidCredentials:
            return "用户名或密码错误"
        case .accountUnavailable:
            return "账号不存在或未开通，请联系管理员"
        case .imInitFailed:
            return "IM 配置无效，请检查 SDKAppID 等"
        case .network:
            return "网络异常，请重试"
        case .userSigExpired:
            return "登录已过期，请重新登录"
        case .kickedOffline:
            return "账号在其他设备登录"
        case .invalidConfigQR:
            return "二维码无效，未修改现有配置"
        case .configQRTooLarge:
            return "配置码过大，导入失败"
        case .catalogUnauthorized:
            return "片库配置无效"
        case .playbackFailed:
            return "无法播放，请稍后重试"
        case .unsupportedContainer:
            return "当前设备暂不支持该封装/编码"
        case .movieChangeFailed:
            return "换片失败"
        case .onlyHostCanSwitchMovie:
            return "仅房主可切换影片"
        case .roomEnded:
            return "房间已结束"
        case .roomNotFound:
            return "房间不存在或邀请已失效"
        case .subtitleUnavailable:
            return "暂无可用字幕"
        case .validation(let message):
            return message
        case .unknown(let message):
            return message
        }
    }
}
