import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

public enum QRCodeImageRenderer {
    public static func image(from string: String, dimension: CGFloat = 240) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = dimension / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

public struct QRCodeView: View {
    let payload: String
    var dimension: CGFloat = 240

    public init(payload: String, dimension: CGFloat = 240) {
        self.payload = payload
        self.dimension = dimension
    }

    public var body: some View {
        Group {
            if let image = QRCodeImageRenderer.image(from: payload, dimension: dimension) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: dimension, height: dimension)
                    .accessibilityLabel("配置二维码")
            } else {
                Text("无法生成二维码")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
