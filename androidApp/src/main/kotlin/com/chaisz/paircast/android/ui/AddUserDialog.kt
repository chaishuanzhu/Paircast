package com.chaisz.paircast.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogProperties
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.CreatedAccount
import kotlinx.coroutines.launch

/** Admin-only: accounts exist only when an admin adds them (no self sign-up). */
@Composable
fun AddUserDialog(app: AppState, onCreated: () -> Unit = {}, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    var email by remember { mutableStateOf("") }
    var nickname by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var created by remember { mutableStateOf<CreatedAccount?>(null) }

    AlertDialog(
        onDismissRequest = { if (!saving) onDismiss() },
        properties = DialogProperties(dismissOnClickOutside = created == null && !saving),
        title = { Text(t(if (created == null) "Add User" else "User added")) },
        text = {
            val result = created
            if (result == null) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    PaircastField(t("Email"), email, { email = it }, keyboardType = KeyboardType.Email)
                    PaircastField(t("Nickname (optional)"), nickname, { nickname = it })
                    Text(
                        t("A random initial password is created. If the server can send email, it goes to this address; otherwise it's shown here for you to pass on. The user must change it at first sign-in."),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("${result.nickname} · ${result.email}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    val password = result.initialPassword
                    if (password != null) {
                        Surface(shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
                            Column(Modifier.fillMaxWidth().padding(14.dp)) {
                                Text(
                                    t("Initial password"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    SelectionContainer(Modifier.weight(1f)) {
                                        Text(password, fontSize = 20.sp, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Monospace)
                                    }
                                    TextButton(onClick = {
                                        clipboard.setText(AnnotatedString(password))
                                        app.showToast(t("Copied"))
                                    }) { Text(t("Copy")) }
                                }
                            }
                        }
                        Text(
                            t("Send this password to the user yourself. It isn't shown again; they must change it at first sign-in."),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else {
                        Text(
                            t("The initial password was emailed to {{email}}. They must change it at first sign-in.", "email" to result.email),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        },
        confirmButton = {
            if (created == null) {
                TextButton(
                    enabled = !saving && email.isNotBlank(),
                    onClick = {
                        scope.launch {
                            saving = true
                            error = null
                            try {
                                created = app.createUser(email, nickname)
                                onCreated()
                            } catch (e: Exception) {
                                error = L10n.message(e, AppError.Network)
                            } finally {
                                saving = false
                            }
                        }
                    },
                ) {
                    if (saving) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text(t("Add"))
                }
            } else {
                TextButton(onClick = onDismiss) { Text(t("Done")) }
            }
        },
        dismissButton = {
            if (created == null) {
                TextButton(onClick = onDismiss, enabled = !saving) { Text(t("Cancel")) }
            } else {
                TextButton(onClick = { created = null; email = ""; nickname = ""; error = null }) { Text(t("Add Another")) }
            }
        },
    )
}
