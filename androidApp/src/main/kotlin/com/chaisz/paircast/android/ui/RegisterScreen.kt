package com.chaisz.paircast.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.rules.RegisterRules
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Email sign-up: request a code, then create the account and sign in. */
@Composable
fun RegisterScreen(app: AppState) {
    val scope = rememberCoroutineScope()
    var email by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var nickname by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var submitting by remember { mutableStateOf(false) }
    var codeSent by remember { mutableStateOf(false) }
    var cooldown by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }

    BackHandler { app.resetToLogin() }
    LaunchedEffect(cooldown > 0) {
        while (cooldown > 0) {
            delay(1_000)
            cooldown--
        }
    }

    fun sendCode() {
        error = null
        scope.launch {
            sending = true
            try {
                cooldown = app.sendRegisterCode(email)
                codeSent = true
                app.showToast(t("Verification code sent"))
            } catch (e: Exception) {
                (e as? AppError.TooManyCodeRequests)?.retryAfterSeconds?.let { cooldown = it }
                error = L10n.message(e)
            } finally {
                sending = false
            }
        }
    }

    fun submit() {
        error = null
        scope.launch {
            submitting = true
            try {
                app.register(email, code, password, confirm, nickname)
            } catch (e: Exception) {
                error = L10n.message(e)
            } finally {
                submitting = false
            }
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .systemBarsPadding()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Spacer(Modifier.height(24.dp))
        Text(t("Create Account"), fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Text(
            t("Sign up with your email. We'll send you a verification code."),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
        )
        Spacer(Modifier.height(8.dp))
        PaircastField(t("Email"), email, { email = it }, keyboardType = KeyboardType.Email)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PaircastField(
                t("Verification code"),
                code,
                { input -> code = input.filter(Char::isDigit).take(RegisterRules.CODE_LENGTH) },
                modifier = Modifier.weight(1f),
                keyboardType = KeyboardType.NumberPassword,
            )
            TextButton(onClick = ::sendCode, enabled = !sending && cooldown == 0 && email.isNotBlank()) {
                Text(
                    when {
                        cooldown > 0 -> t("Resend in {{count}}s", "count" to "$cooldown")
                        codeSent -> t("Resend")
                        else -> t("Send Code")
                    },
                )
            }
        }
        PaircastField(t("Password"), password, { password = it }, secure = true)
        PaircastField(t("Confirm password"), confirm, { confirm = it }, secure = true)
        PaircastField(t("Nickname (optional)"), nickname, { nickname = it })
        TermsAgreementRow(app)
        error?.let {
            Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.fillMaxWidth())
        }
        PrimaryButton(
            t("Create Account"),
            ::submit,
            loading = submitting,
            enabled = email.isNotBlank() && code.length == RegisterRules.CODE_LENGTH && password.isNotEmpty() && confirm.isNotEmpty(),
        )
        TextButton(onClick = { app.resetToLogin() }) {
            Text(t("Already have an account? Sign In"), fontSize = 15.sp)
        }
    }
}
