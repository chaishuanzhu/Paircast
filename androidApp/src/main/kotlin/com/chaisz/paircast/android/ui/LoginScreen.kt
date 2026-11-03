package com.chaisz.paircast.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogProperties
import com.chaisz.paircast.android.R
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.core.model.AppError
import kotlinx.coroutines.launch

@Composable
fun LoginScreen(app: AppState) {
    val scope = rememberCoroutineScope()
    var account by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var showConfigAlert by remember { mutableStateOf(false) }
    val config = app.config
    val configured = config?.isComplete == true

    fun submit() {
        error = null
        if (!configured) {
            showConfigAlert = true
            return
        }
        scope.launch {
            loading = true
            try {
                app.login(account, password)
                password = ""
            } catch (e: Exception) {
                error = L10n.message(e)
            } finally {
                loading = false
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
        Spacer(Modifier.height(48.dp))
        Image(
            painterResource(R.drawable.brand_mark),
            contentDescription = null,
            modifier = Modifier.size(72.dp).clip(RoundedCornerShape(18.dp)),
        )
        Text("Paircast", fontSize = 34.sp, fontWeight = FontWeight.Bold)
        Text(t("Watch together"), color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(16.dp))
        PaircastField(t("Account"), account, { account = it })
        PaircastField(t("Password"), password, { password = it }, secure = true)
        if (config != null && config.im.isComplete) {
            Text(
                config.im.maskedSummary,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.fillMaxWidth(),
            )
        } else {
            Text(
                t("Finish service configuration first"),
                style = MaterialTheme.typography.bodySmall,
                color = androidx.compose.ui.graphics.Color(0xFFFF9500),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        TermsAgreementRow(app)
        error?.let {
            Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.fillMaxWidth())
        }
        PrimaryButton(t("Sign In"), ::submit, loading = loading)
        TextButton(onClick = { app.openConfig(fromLogin = true) }) {
            Text(t("Service Configuration"), fontSize = 17.sp)
        }
        if (configured) {
            Text(
                t("Accounts are assigned by an admin · No sign-up"),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
                textAlign = TextAlign.Center,
            )
        }
    }

    if (showConfigAlert) {
        AlertDialog(
            onDismissRequest = { showConfigAlert = false },
            title = { Text(t("Finish service configuration first")) },
            confirmButton = {
                TextButton(onClick = { showConfigAlert = false; app.openConfig(fromLogin = true) }) { Text(t("Configure")) }
            },
            dismissButton = { TextButton(onClick = { showConfigAlert = false }) { Text(t("Cancel")) } },
        )
    }
    if (app.mustChangePassword) {
        ChangePasswordDialog(app, forced = true, onDismiss = {})
    }
}

/** Change password; `forced` right after a login the server flagged `must_change_password`. */
@Composable
fun ChangePasswordDialog(app: AppState, forced: Boolean, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var old by remember { mutableStateOf("") }
    var new by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = { if (!forced) onDismiss() },
        properties = DialogProperties(dismissOnBackPress = !forced, dismissOnClickOutside = !forced),
        title = { Text(t("Change Password")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (forced) {
                    Text(t("Your administrator requires a new password before you continue."), style = MaterialTheme.typography.bodySmall)
                }
                PaircastField(t("Current password"), old, { old = it }, secure = true)
                PaircastField(t("New password"), new, { new = it }, secure = true)
                PaircastField(t("Confirm new password"), confirm, { confirm = it }, secure = true)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !saving && old.isNotEmpty() && new.isNotEmpty(),
                onClick = {
                    scope.launch {
                        saving = true
                        error = null
                        try {
                            app.changePassword(old, new, confirm)
                            if (!forced) onDismiss()
                        } catch (e: Exception) {
                            error = L10n.message(e, AppError.PasswordChangeFailed)
                        } finally {
                            saving = false
                        }
                    }
                },
            ) { Text(t("Save")) }
        },
        dismissButton = {
            TextButton(onClick = { if (forced) app.cancelForcedPasswordChange() else onDismiss() }) {
                Text(t(if (forced) "Sign Out" else "Cancel"))
            }
        },
    )
}
