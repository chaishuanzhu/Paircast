import SwiftUI
import UIKit
import Domain

/// Chat composer that shows Twemoji images inline while storing Unicode in `text`.
struct TwemojiComposerField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEmojiPanelOpen: Bool
    var onBeganEditing: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PaddingTextView {
        let view = PaddingTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        view.textContainer.lineFragmentPadding = 0
        view.font = TwemojiComposerStyle.font
        view.textColor = .label
        view.tintColor = UIColor(TandemColors.systemBlue)
        view.isScrollEnabled = false
        view.returnKeyType = .default
        view.autocorrectionType = .yes
        view.spellCheckingType = .no
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)

        let placeholderLabel = UILabel()
        placeholderLabel.text = placeholder
        placeholderLabel.font = TwemojiComposerStyle.font
        placeholderLabel.textColor = .tertiaryLabel
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.tag = 9_901
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -14),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        context.coordinator.attach(view)
        context.coordinator.reload(from: text, force: true)
        return view
    }

    func updateUIView(_ uiView: PaddingTextView, context: Context) {
        context.coordinator.parent = self
        if let label = uiView.viewWithTag(9_901) as? UILabel {
            label.text = placeholder
        }
        let current = TwemojiComposerStyle.plainString(from: uiView.attributedText)
        if current != text {
            context.coordinator.reload(from: text, force: true)
        }
        context.coordinator.updatePlaceholder()
        if isEmojiPanelOpen, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TwemojiComposerField
        private weak var textView: PaddingTextView?
        private var isApplying = false

        init(_ parent: TwemojiComposerField) {
            self.parent = parent
        }

        func attach(_ view: PaddingTextView) {
            textView = view
        }

        func updatePlaceholder() {
            guard let textView,
                  let label = textView.viewWithTag(9_901) else { return }
            let plain = TwemojiComposerStyle.plainString(from: textView.attributedText)
            label.isHidden = !plain.isEmpty
        }

        func reload(from plain: String, force: Bool) {
            guard let textView else { return }
            let current = TwemojiComposerStyle.plainString(from: textView.attributedText)
            guard force || current != plain else {
                updatePlaceholder()
                return
            }
            isApplying = true
            defer { isApplying = false }

            // Warm any missing images, then build with whatever is already available.
            for ch in plain where ch.isTwemojiCandidate {
                let glyph = String(ch)
                if TwemojiImageCache.imageSyncIfCached(forEmoji: glyph) == nil {
                    TwemojiImageCache.image(forEmoji: glyph) { [weak self] image in
                        guard image != nil, let self else { return }
                        self.reload(from: self.parent.text, force: true)
                    }
                }
            }

            let selected = textView.selectedRange
            textView.attributedText = TwemojiComposerStyle.attributed(from: plain)
            let maxLoc = textView.attributedText.length
            textView.selectedRange = NSRange(location: min(selected.location, maxLoc), length: 0)
            updatePlaceholder()
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onBeganEditing?()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplying else { return }
            let plain = TwemojiComposerStyle.plainString(from: textView.attributedText)
            if parent.text != plain {
                parent.text = plain
            }
            updatePlaceholder()
            // Upgrade system glyphs → Twemoji when local/CDN images become ready.
            let emojiCount = plain.reduce(0) { $0 + ($1.isTwemojiCandidate ? 1 : 0) }
            var attachmentCount = 0
            textView.attributedText.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: textView.attributedText.length),
                options: []
            ) { value, _, _ in
                if value is TwemojiAttachment { attachmentCount += 1 }
            }
            if emojiCount > attachmentCount {
                reload(from: plain, force: true)
            } else {
                (textView as? PaddingTextView)?.invalidateIntrinsicContentSize()
            }
        }
    }
}

/// Fixed vertical metrics so SwiftUI layout matches the previous capsule TextField.
final class PaddingTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let fitting = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = min(max(fitting.height, 40), 88)
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }
}

enum TwemojiComposerStyle {
    static let font = UIFont.systemFont(ofSize: 15)
    static let emojiSide: CGFloat = 18

    static func plainString(from attributed: NSAttributedString?) -> String {
        guard let attributed else { return "" }
        var result = ""
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? TwemojiAttachment {
                result += attachment.emoji
            } else {
                result += (attributed.string as NSString).substring(with: range)
            }
        }
        return result
    }

    static func attributed(from plain: String, textColor: UIColor = .label) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        for ch in plain {
            let glyph = String(ch)
            if ch.isTwemojiCandidate,
               let image = TwemojiImageCache.imageSyncIfCached(forEmoji: glyph) {
                result.append(NSAttributedString(attachment: TwemojiAttachment(emoji: glyph, image: image, side: emojiSide)))
            } else {
                result.append(NSAttributedString(string: glyph, attributes: attrs))
            }
        }
        return result
    }
}

final class TwemojiAttachment: NSTextAttachment {
    let emoji: String

    init(emoji: String, image: UIImage, side: CGFloat) {
        self.emoji = emoji
        super.init(data: nil, ofType: nil)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        self.image = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: CGSize(width: side, height: side)))
        }.withRenderingMode(.alwaysOriginal)
        bounds = CGRect(x: 0, y: -side * 0.2, width: side, height: side)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
