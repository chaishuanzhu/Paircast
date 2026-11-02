import SwiftUI
import PaircastShared

/// "I have read and agree to the Terms of Service and Privacy Policy" — links open the public pages.
struct TermsAgreementView: View {
    @ObservedObject var session: AppSession
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                session.agreedToTerms.toggle()
            } label: {
                Image(systemName: session.agreedToTerms ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(session.agreedToTerms ? TandemColors.systemBlue : TandemColors.tertiaryLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(TandemL10n.string("Agree to the Terms of Service and Privacy Policy"))
            .accessibilityAddTraits(session.agreedToTerms ? .isSelected : [])

            Text(agreementText)
                .font(.footnote)
                .foregroundStyle(TandemColors.secondaryLabel)
                .tint(TandemColors.systemBlue)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var agreementText: AttributedString {
        let chinese = locale.identifier.hasPrefix("zh")
        let terms = "[\(TandemL10n.string("Terms of Service"))](\(LegalRules.shared.termsUrl(chinese: chinese)))"
        let privacy = "[\(TandemL10n.string("Privacy Policy"))](\(LegalRules.shared.privacyUrl(chinese: chinese)))"
        let markdown = TandemL10n.format(
            "I have read and agree to the {{terms}} and {{privacy}}",
            ["terms": terms, "privacy": privacy]
        )
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}
