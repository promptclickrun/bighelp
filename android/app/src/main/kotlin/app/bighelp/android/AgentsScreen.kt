package app.bighelp.android

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** Pick which sample agent new chats start with. */
@Composable
fun AgentsScreen(
    demo: DemoState,
    onSelect: (String) -> Unit,
    onNewChat: () -> Unit,
    onOpenPlace: (Route) -> Unit,
) {
    val selected = demo.agent(demo.selectedAgentId)
    Column(Modifier.fillMaxSize().safeDrawingPadding().testTag("screen.agents")) {
        ScreenHeader("Agents", leading = { PlacesMenu(current = Route.Agents, onOpen = onOpenPlace) })
        DemoBanner(Modifier.padding(horizontal = 16.dp))
        Text(
            "New chats start with the agent you pick.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
        )
        LazyColumn(Modifier.weight(1f).testTag("agents.list")) {
            items(demo.agents, key = { it.id }) { agent ->
                val isSelected = agent.id == demo.selectedAgentId
                Row(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 72.dp)
                        .selectable(selected = isSelected, role = Role.RadioButton, onClick = { onSelect(agent.id) })
                        .padding(horizontal = 16.dp, vertical = 10.dp)
                        .testTag("agents.row.${agent.id}"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    AgentAvatar(agent)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(agent.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text(agent.role, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (isSelected) Icon(Icons.Default.Check, contentDescription = "Selected")
                }
            }
        }
        InkButton(
            "New chat with ${selected.name}",
            onNewChat,
            tag = "agents.new-chat",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
        )
    }
}
