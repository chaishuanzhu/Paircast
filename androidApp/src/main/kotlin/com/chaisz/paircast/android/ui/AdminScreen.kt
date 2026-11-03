package com.chaisz.paircast.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.PersonAdd
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.core.model.ReportFilter

/** Admin-only hub: user management, adding users and chat reports. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdminScreen(app: AppState) {
    var showAddUser by remember { mutableStateOf(false) }
    var pendingReports by remember { mutableStateOf(0) }

    BackHandler { app.popLibrary() }
    LaunchedEffect(Unit) {
        pendingReports = runCatching { app.graph.loadReports(ReportFilter.PENDING, 0, 1).pending }.getOrDefault(0)
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(t("Admin Console")) },
                navigationIcon = {
                    IconButton(onClick = app::popLibrary) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = t("Back")) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
            Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surface) {
                Column {
                    AdminRow(Icons.Outlined.Group, PaircastColors.blue, t("User Management")) { app.openUsers() }
                    HorizontalDivider(Modifier.padding(start = 60.dp))
                    AdminRow(Icons.Outlined.PersonAdd, PaircastColors.green, t("Add User")) { showAddUser = true }
                    HorizontalDivider(Modifier.padding(start = 60.dp))
                    AdminRow(Icons.Outlined.Flag, MaterialTheme.colorScheme.error, t("Reports"), badge = pendingReports) { app.openReports() }
                }
            }
        }
    }

    if (showAddUser) AddUserDialog(app) { showAddUser = false }
}

@Composable
private fun AdminRow(icon: ImageVector, tint: Color, title: String, badge: Int = 0, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(28.dp))
        Spacer(Modifier.width(16.dp))
        Text(title, modifier = Modifier.weight(1f))
        if (badge > 0) {
            Text(
                "$badge",
                color = Color.White,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier
                    .background(MaterialTheme.colorScheme.error, CircleShape)
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            )
            Spacer(Modifier.width(6.dp))
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.outline,
        )
    }
}
