package app.bighelp.android

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** The Chats place: search, then the sample chats, newest activity first. */
@Composable
fun SessionsScreen(
    demo: DemoState,
    onSearch: (String) -> Unit,
    onOpenChat: (String) -> Unit,
    onNewChat: () -> Unit,
    onOpenPlace: (Route) -> Unit,
) {
    val visible = demo.visibleSessions
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
            },
        )
        DemoBanner(Modifier.padding(horizontal = 16.dp))
        Spacer(Modifier.height(12.dp))
        BighelpSearchField(
            value = demo.search,
            onValueChange = onSearch,
            placeholder = "Search chats",
            tag = "sessions.search",
            modifier = Modifier.padding(horizontal = 16.dp),
        )
        Spacer(Modifier.height(4.dp))
        if (visible.isEmpty()) {
            Column(
                Modifier.fillMaxWidth().padding(24.dp).testTag("sessions.empty"),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("No chats match", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(
                    "Nothing in the sample chats mentions that.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                TextButton(onClick = { onSearch("") }, modifier = Modifier.testTag("sessions.empty.clear")) {
                    Text("Clear search")
                }
            }
        } else {
            LazyColumn(Modifier.weight(1f).testTag("sessions.list")) {
                items(visible, key = { it.id }) { session ->
                    SessionRow(
                        session = session,
                        agent = demo.agent(session.agentId),
                        draft = demo.drafts[session.id],
                        onClick = { onOpenChat(session.id) },
                    )
                }
            }
        }
    }
}

@Composable
private fun SessionRow(session: DemoSession, agent: DemoAgent, draft: String?, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 72.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp)
            .testTag("sessions.row.${session.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AgentAvatar(agent)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(
                session.title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(agent.name, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            val preview = when {
                draft != null -> "Draft: ${draft.trim().replace('\n', ' ')}"
                session.messages.isEmpty() -> "No messages yet"
                else -> session.messages.last().text.replace('\n', ' ')
            }
            Text(
                preview,
                style = MaterialTheme.typography.bodyMedium,
                color = if (draft != null) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                fontWeight = if (draft != null) FontWeight.Medium else FontWeight.Normal,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
