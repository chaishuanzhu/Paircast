import Foundation

public enum ProfileRules {
    public static let nicknameMinLength = 1
    public static let nicknameMaxLength = 16

    public static func validatedNickname(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.validation("昵称不能为空")
        }
        guard trimmed.count <= nicknameMaxLength else {
            throw AppError.validation("昵称最多 \(nicknameMaxLength) 字")
        }
        return trimmed
    }
}

public enum LoginRules {
    public static func validateCredentials(userId: String, password: String) throws {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw AppError.validation("请输入用户名")
        }
        // Scheme A: password only needs to be non-empty; real auth is IM login.
        guard !password.isEmpty else {
            throw AppError.validation("请输入密码")
        }
    }
}

public enum ConfigValidation {
    public static func missingFields(in config: AppCloudConfig) -> [String] {
        var missing: [String] = []
        if config.im.sdkAppId <= 0 { missing.append("IM SDKAppID") }
        if config.im.secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("IM SecretKey")
        }
        if config.qiniu.accessKey.isEmpty { missing.append("七牛 AccessKey") }
        if config.qiniu.secretKey.isEmpty { missing.append("七牛 SecretKey") }
        if config.qiniu.bucket.isEmpty { missing.append("七牛 Bucket") }
        if config.qiniu.endpoint.isEmpty { missing.append("七牛 Endpoint") }
        return missing
    }

    public static func validate(_ config: AppCloudConfig) throws {
        let missing = missingFields(in: config)
        if !missing.isEmpty {
            throw AppError.incompleteConfig(missing: missing)
        }
    }
}
