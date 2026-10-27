package app.bighelp.android

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.bighelp.android.live.LiveModel
import app.bighelp.android.live.RowStatus
import app.bighelp.android.live.SessionListing
import app.bighelp.android.live.SessionRowUi
import app.bighelp.hermes.chat.ConversationRef
import app.bighelp.hermes.chat.SessionSummary
import kotlinx.coroutines.launch

/** What a chat row's long-press can do, kept as data so the menu and the dialogs share one source. */
private enum class RowAction { Rename, Archive, Delete }

/** The Chats place for a real computer: its saved chats, newest first, with search, refresh and per-chat actions. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LiveSessionsScreen(
    live: LiveModel<*>,
    onOpenChat: (ConversationRef) -> Unit,
    onNewChat: () -> Unit,
    onOpenArchived: () -> Unit,
    onOpenPlace: (Route) -> Unit,
    onSignInAgain: () -> Unit,
) {
    val catalog by live.catalog.collectAsStateWithLifecycle()
    val conversations by live.conversations.collectAsStateWithLifecycle()
    val search by live.searchText.collectAsStateWithLifecycle()
    val hits by live.contentHits.collectAsStateWithLifecycle()
    val link by live.link.collectAsStateWithLifecycle()
    val problem by live.reconnectProblem.collectAsStateWithLifecycle()
    val pending by live.pendingCreations.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    var action by remember { mutableStateOf<Pair<RowAction, SessionRowUi>?>(null) }
    val rows = SessionListing.rows(catalog, conversations, search)
    val now = System.currentTimeMillis()

    Column(Modifier.fillMaxSize().safeDrawingPadding().testTag("screen.sessions")) {
        ScreenHeader(
            "Chats",
            leading = { PlacesMenu(current = Route.Sessions, onOpen = onOpenPlace) },
            trailing = {
                TextButton(onClick = onNewChat, modifier = Modifier.heightIn(min = 48.dp).testTag("sessions.new-chat")) {
                    Icon(Icons.Default.Add, contentDescription = null)
                    Spacer(Modifier.width(4.dp))
                    Text("New chat")
                }
                Box {
                    IconButton(onClick = { menuOpen = true }, modifier = Modifier.testTag("sessions.more")) {
                        Icon(Icons.Default.MoreVert, contentDescription = "More")
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(text = { Text("Archived chats") }, onClick = { menuOpen = false; onOpenArchived() }, modifier = Modifier.testTag("sessions.archived"))
                        DropdownMenuItem(
                            text = { Text("Refresh") },
                            onClick = { menuOpen = false; scope.launch { refreshing = true; live.refresh(); refreshing = false } },
                            modifier = Modifier.testTag("sessions.refresh"),
                        )
                    }
                }
            },
        )
        LinkBanner(link, problem, onReconnect = live::reconnectNow, onSignInAgain = onSignInAgain, modifier = Modifier.padding(horizontal = 16.dp))
        pending.forEach { creation ->
            PendingCreationBanner(
                onRetry = { scope.launch { live.retryCreation(creation.profile, creation.intentId)?.let(onOpenChat) } },
                onDiscard = { scope.launch { live.discardCreation(creation.profile) } },
            )
        }
        Spacer(Modifier.height(8.dp))
        BighelpSearchField(
            value = search, onValueChange = live::setSearch, placeholder = "Search chats", tag = "sessions.search",
            modifier = Modifier.padding(horizontal = 16.dp),
        )
        Spacer(Modifier.height(4.dp))
        PullToRefreshBox(
            isRefreshing = refreshing || catalog.loading,
            onRefresh = { scope.launch { refreshing = true; live.refresh(); refreshing = false } },
            modifier = Modifier.weight(1f).fillMaxWidth(),
        ) {
            when {
                rows.isEmpty() && hits.isEmpty() -> Column(Modifier.fillMaxSize()) {
                    when {
                        // Until the first read finishes or fails, the list is not known to be empty.
                        catalog.loadedAtMillis == null && catalog.error == null -> EmptyState("Loading your chats…", "This takes a moment.", "sessions.loading")
                        catalog.error != null && catalog.sessions.isEmpty() -> EmptyState(
                            "Couldn't load your chats", app.bighelp.android.live.LiveText.describe(catalog.error!!), "sessions.error",
                        ) { TextButton(onClick = { scope.launch { live.refresh() } }, modifier = Modifier.testTag("sessions.retry")) { Text("Try again") } }
                        search.isNotBlank() -> EmptyState("No chats match", "Nothing in your chats matches that.", "sessions.empty")
                        else -> EmptyState("No chats yet", "Start one with New chat. Nothing is created until you ask.", "sessions.empty")
                    }
                }
                else -> LazyColumn(Modifier.fillMaxSize().testTag("sessions.list")) {
                    items(rows, key = { it.ref.id }) { row ->
                        SessionRow(row, now, onClick = { onOpenChat(row.ref) }, onAction = { chosen -> action = chosen to row })
                    }
                    if (hits.isNotEmpty()) {
                        item(key = "hits.label") { SectionLabel("Messages that match", Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp)) }
                        items(hits, key = { "hit:" + it.ref.id }) { hit ->
                            Column(Modifier.fillMaxWidth().clickable { onOpenChat(hit.ref) }.padding(horizontal = 16.dp, vertical = 10.dp).testTag("sessions.hit.${hit.ref.id}")) {
                                Text(hit.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(hit.agentName, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(hit.snippet, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                }
            }
        }
    }
    action?.let { (what, row) ->
        when (what) {
            RowAction.Rename -> TextEntryDialog("Rename chat", row.title, "Rename", onConfirm = { title -> action = null; scope.launch { live.rename(row.ref, title) } }, onDismiss = { action = null }, tag = "dialog.rename")
            RowAction.Archive -> ConfirmDialog("Archive this chat?", "It leaves the list and stays in Archived chats. You can restore it.", "Archive", { action = null; scope.launch { live.archive(row.ref) } }, { action = null }, "dialog.archive")
            RowAction.Delete -> ConfirmDialog("Delete this chat?", "It is deleted from your computer. This can't be undone.", "Delete", { action = null; scope.launch { live.delete(row.ref) } }, { action = null }, "dialog.delete")
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionRow(row: SessionRowUi, nowMillis: Long, onClick: () -> Unit, onAction: (RowAction) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 72.dp)
                .combinedClickable(onClick = onClick, onLongClick = { menu = true })
                .padding(horizontal = 16.dp, vertical = 10.dp)
                .testTag("sessions.row.${row.ref.id}"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            LiveAvatar(row.agentName, row.ref.profile)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(row.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    val time = SessionListing.relativeTime(row.lastActiveEpochSeconds, nowMillis)
                    if (time.isNotEmpty()) Text(time, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(row.agentName, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                val status = when (row.status) {
                    RowStatus.NeedsYou -> "Needs you"
                    RowStatus.Working -> "Working…"
                    RowStatus.Idle -> null
                }
                Text(
                    status ?: row.preview.ifEmpty { "No messages yet" },
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = if (status != null) FontWeight.Medium else FontWeight.Normal,
                    color = if (status != null) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; onAction(RowAction.Rename) }, modifier = Modifier.testTag("row.rename"))
            DropdownMenuItem(text = { Text("Archive") }, onClick = { menu = false; onAction(RowAction.Archive) }, modifier = Modifier.testTag("row.archive"))
            DropdownMenuItem(text = { Text("Delete") }, onClick = { menu = false; onAction(RowAction.Delete) }, modifier = Modifier.testTag("row.delete"))
        }
    }
}

@Composable
private fun PendingCreationBanner(onRetry: () -> Unit, onDiscard: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).testTag("sessions.pending")) {
        Text("A new chat wasn't confirmed.", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
        Text("Retry makes the same chat again, so you never get two.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row {
            TextButton(onClick = onRetry, modifier = Modifier.testTag("sessions.pending.retry")) { Text("Retry") }
            TextButton(onClick = onDiscard, modifier = Modifier.testTag("sessions.pending.discard")) { Text("Discard") }
        }
    }
}

/** Chats someone archived on purpose. Restore brings one back to the list; Delete removes it from the computer. */
@Composable
internal fun ArchivedChatsScreen(live: LiveModel<*>, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var chats by remember { mutableStateOf<List<SessionSummary>?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    var deleting by remember { mutableStateOf<SessionSummary?>(null) }
    LaunchedEffect(reload) { chats = live.archived() ?: emptyList() }
    Column(Modifier.fillMaxSize().safeDrawingPadding().testTag("screen.archived")) {
        ScreenHeader("Archived chats", leading = { BackButton(onBack) })
        val list = chats
        when {
            list == null -> EmptyState("Loading…", "Reading your archived chats.", "archived.loading")
            list.isEmpty() -> EmptyState("Nothing archived", "Chats you archive show up here.", "archived.empty")
            else -> LazyColumn(Modifier.weight(1f).testTag("archived.list")) {
                items(list, key = { it.ref.id }) { chat ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(chat.title.ifBlank { "Chat" }, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(chat.profile, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        TextButton(onClick = { scope.launch { live.restore(chat.ref); reload++ } }, modifier = Modifier.testTag("archived.restore.${chat.ref.id}")) { Text("Restore") }
                        TextButton(onClick = { deleting = chat }, modifier = Modifier.testTag("archived.delete.${chat.ref.id}")) { Text("Delete") }
                    }
                }
            }
        }
    }
    deleting?.let { chat ->
        ConfirmDialog("Delete this chat?", "It is deleted from your computer. This can't be undone.", "Delete", { deleting = null; scope.launch { live.delete(chat.ref); reload++ } }, { deleting = null }, "dialog.delete-archived")
    }
}

/** Agents of the open computer: pick the one new chats start with, start a chat, or open its Bot Chat. */
@Composable
internal fun LiveAgentsScreen(
    live: LiveModel<*>,
    onNewChat: (String) -> Unit,
    onBotChat: (String) -> Unit,
    onOpenPlace: (Route) -> Unit,
    onSignInAgain: () -> Unit,
) {
    val catalog by live.catalog.collectAsStateWithLifecycle()
    val selected by live.selectedAgentId.collectAsStateWithLifecycle()
    val link by live.link.collectAsStateWithLifecycle()
    val problem by live.reconnectProblem.collectAsStateWithLifecycle()
    val agent = catalog.agents.firstOrNull { it.id == selected }
    Column(Modifier.fillMaxSize().safeDrawingPadding().testTag("screen.agents")) {
        ScreenHeader("Agents", leading = { PlacesMenu(current = Route.Agents, onOpen = onOpenPlace) })
        LinkBanner(link, problem, onReconnect = live::reconnectNow, onSignInAgain = onSignInAgain, modifier = Modifier.padding(horizontal = 16.dp))
        Text(
            "New chats start with the agent you pick.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
        )
        if (catalog.agents.isEmpty()) {
            EmptyState(
                if (catalog.loading) "Loading your agents…" else "No agents found",
                if (catalog.error != null) app.bighelp.android.live.LiveText.describe(catalog.error!!) else "Your computer didn't list any agents yet.",
                "agents.empty",
            )
        }
        LazyColumn(Modifier.weight(1f).testTag("agents.list")) {
            items(catalog.agents.distinctBy { it.id }, key = { it.id }) { each ->
                val isSelected = each.id == selected
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 72.dp)
                        .selectable(selected = isSelected, role = Role.RadioButton, onClick = { live.selectAgent(each.id) })
                        .padding(horizontal = 16.dp, vertical = 10.dp).testTag("agents.row.${each.id}"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    LiveAvatar(each.displayName, each.id)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(each.displayName.ifBlank { each.id }, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        catalog.agentErrors[each.id]?.let {
                            Text("Its chats couldn't be read.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    if (isSelected) Icon(Icons.Default.Check, contentDescription = "Selected")
                }
            }
        }
        if (agent != null) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                InkButton("New chat with ${agent.displayName.ifBlank { agent.id }}", { onNewChat(agent.id) }, tag = "agents.new-chat")
                InkOutlinedButton("Open ${agent.displayName.ifBlank { agent.id }}'s Bot Chat", { onBotChat(agent.id) }, tag = "agents.bot-chat")
            }
        }
    }
}
