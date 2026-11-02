package com.chaisz.paircast.android.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withLink
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.core.rules.LegalRules

/** "I have read and agree to the Terms of Service and Privacy Policy" — links open the public pages. */
@Composable
fun TermsAgreementRow(app: AppState) {
    val chinese = L10n.useChinese
    val links = listOf(
        "{{terms}}" to (t("Terms of Service") to LegalRules.termsUrl(chinese)),
        "{{privacy}}" to (t("Privacy Policy") to LegalRules.privacyUrl(chinese)),
    )
    val linkStyle = TextLinkStyles(SpanStyle(color = MaterialTheme.colorScheme.primary))
    val text = buildAnnotatedString {
        var rest = t("I have read and agree to the {{terms}} and {{privacy}}")
        while (rest.isNotEmpty()) {
            val next = links.mapNotNull { (token, link) -> rest.indexOf(token).takeIf { it >= 0 }?.let { Triple(it, token, link) } }
                .minByOrNull { it.first }
            if (next == null) {
                append(rest)
                break
            }
            val (index, token, link) = next
            append(rest.substring(0, index))
            withLink(LinkAnnotation.Url(link.second, linkStyle)) { append(link.first) }
            rest = rest.substring(index + token.length)
        }
    }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked = app.agreedToTerms, onCheckedChange = { app.agreedToTerms = it })
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
