package com.chaisz.paircast.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.PersonAdd
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ManagedUser
import com.chaisz.paircast.core.rules.AccountRules
import com.chaisz.paircast.core.usecase.LoadUsersUseCase
import kotlinx.coroutines.launch

private enum class UserAction { DISABLE, ENABLE, DELETE }

/** Admin-only: list accounts, disable / enable or delete regular users. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UsersScreen(app: AppState) {
    val scope = rememberCoroutineScope()
    val users = remember { mutableStateListOf<ManagedUser>() }
    var total by remember { mutableIntStateOf(0) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var busyId by remember { mutableStateOf<String?>(null) }
    var confirm by remember { mutableStateOf<Pair<ManagedUser, UserAction>?>(null) }
    var reloadKey by remember { mutableIntStateOf(0) }
    var showAddUser by remember { mutableStateOf(false) }
    val selfId = app.currentUser?.id

    BackHandler { app.popLibrary() }

    suspend fun load(append: Boolean) {
        loading = true
        error = null
        try {
            val page = app.graph.loadUsers(if (append) users.size else 0, LoadUsersUseCase.PAGE_SIZE)
            if (!append) users.clear()
            users.addAll(page.users.filter { u -> users.none { it.id == u.id } })
            total = page.total
        } catch (e: Exception) {
            error = L10n.message(e, AppError.Network)
        } finally {
            loading = false
        }
    }

    LaunchedEffect(reloadKey) { load(append = false) }

    fun perform(user: ManagedUser, action: UserAction) {
        scope.launch {
            busyId = user.id
            try {
                when (action) {
                    UserAction.DELETE -> {
                        app.graph.deleteUser(user)
                        users.removeAll { it.id == user.id }
                        total = (total - 1).coerceAtLeast(0)
                        app.showToast(t("Deleted {{name}}", "name" to user.displayName))
                    }
                    else -> {
                        val disabled = action == UserAction.DISABLE
                        app.graph.setUserDisabled(user, disabled)
                        val index = users.indexOfFirst { it.id == user.id }
                        if (index >= 0) users[index] = users[index].copy(isDisabled = disabled)
                        app.showToast(t(if (disabled) "Disabled {{name}}" else "Enabled {{name}}", "name" to user.displayName))
                    }
                }
            } catch (e: Exception) {
                app.showToast(L10n.message(e, AppError.Network))
            } finally {
                busyId = null
            }
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(t("User Management")) },
                navigationIcon = {
                    IconButton(onClick = app::popLibrary) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = t("Back")) }
                },
                actions = {
                    IconButton(onClick = { showAddUser = true }) {
                        Icon(Icons.Outlined.PersonAdd, contentDescription = t("Add User"))
                    }
                    IconButton(onClick = { reloadKey++ }, enabled = !loading) {
                        Icon(Icons.Filled.Refresh, contentDescription = t("Refresh"))
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                users.isEmpty() && loading -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                users.isEmpty() -> Column(
                    Modifier.fillMaxSize().padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Text(error ?: t("No users yet"), color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                    if (error != null) TextButton(onClick = { reloadKey++ }) { Text(t("Retry")) }
                }
                else -> LazyColumn(
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 32.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    item {
                        Text(
                            t("Total: {{count}}", "count" to "$total"),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 4.dp, bottom = 4.dp),
                        )
                    }
                    items(users, key = { it.id }) { user ->
                        UserCard(
                            user,
                            isSelf = user.id == selfId,
                            manageable = AccountRules.canManage(user, selfId),
                            busy = busyId == user.id,
                            onAction = { action ->
                                if (action == UserAction.ENABLE) perform(user, action) else confirm = user to action
                            },
                        )
                    }
                    if (users.size < total) {
                        item {
                            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                                if (loading) {
                                    CircularProgressIndicator(Modifier.padding(8.dp))
                                } else {
                                    TextButton(onClick = { scope.launch { load(append = true) } }) { Text(t("Load more")) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    confirm?.let { (user, action) ->
        val deleting = action == UserAction.DELETE
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text(t(if (deleting) "Delete {{name}}?" else "Disable {{name}}?", "name" to user.displayName)) },
            text = {
                Text(
                    t(
                        if (deleting) {
                            "This permanently deletes the account and signs it out. The email can be added again later."
                        } else {
                            "They are signed out right away and can't sign in until you enable the account again."
                        },
                    ),
                )
            },
            confirmButton = {
                TextButton(onClick = { confirm = null; perform(user, action) }) {
                    Text(t(if (deleting) "Delete" else "Disable"), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text(t("Cancel")) } },
        )
    }

    if (showAddUser) AddUserDialog(app, onCreated = { reloadKey++ }) { showAddUser = false }
}

@Composable
private fun UserCard(
    user: ManagedUser,
    isSelf: Boolean,
    manageable: Boolean,
    busy: Boolean,
    onAction: (UserAction) -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surface) {
        Row(Modifier.fillMaxWidth().padding(start = 14.dp, top = 12.dp, bottom = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Avatar(user.displayName, user.avatarUrl, 40.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        user.displayName,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (isSelf) UserBadge(t("You"), MaterialTheme.colorScheme.outline)
                    if (user.isAdmin) UserBadge(t("Admin"), PaircastColors.blue)
                    if (user.isDisabled) UserBadge(t("Disabled"), MaterialTheme.colorScheme.error)
                }
                Text(
                    listOfNotNull(user.email, "UID ${user.id}").joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (busy) {
                CircularProgressIndicator(Modifier.padding(12.dp).size(20.dp), strokeWidth = 2.dp)
            } else if (manageable) {
                Box {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = t("More")) }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(
                            text = { Text(t(if (user.isDisabled) "Enable" else "Disable")) },
                            onClick = { menu = false; onAction(if (user.isDisabled) UserAction.ENABLE else UserAction.DISABLE) },
                        )
                        DropdownMenuItem(
                            text = { Text(t("Delete"), color = MaterialTheme.colorScheme.error) },
                            onClick = { menu = false; onAction(UserAction.DELETE) },
                        )
                    }
                }
            } else {
                Spacer(Modifier.width(12.dp))
            }
        }
    }
}

@Composable
private fun UserBadge(label: String, color: Color) {
    Text(
        label,
        color = color,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        maxLines = 1,
        modifier = Modifier.background(color.copy(alpha = 0.12f), CircleShape).padding(horizontal = 8.dp, vertical = 2.dp),
    )
}
