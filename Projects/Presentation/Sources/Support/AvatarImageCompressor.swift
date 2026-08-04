import UIKit
import Domain

enum AvatarImageCompressor {
    static func jpegData(from raw: Data, maxBytes: Int = ProfileRules.avatarMaxBytes) -> Data? {
        guard var image = UIImage(data: raw) else { return nil }
        let maxSide: CGFloat = 1024
        let longest = max(image.size.width, image.size.height)
        if longest > maxSide {
            let scale = maxSide / longest
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            image = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        var quality: CGFloat = 0.88
        var data = image.jpegData(compressionQuality: quality)
        while let current = data, current.count > maxBytes, quality > 0.35 {
            quality -= 0.12
            data = image.jpegData(compressionQuality: quality)
        }
        guard let final = data, final.count <= maxBytes else { return nil }
        return final
    }
}
