package app.bighelp.android

import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * The one menu. It owns every place outside the chat list (Agents, Settings), so no screen carries a
 * second menu or its own copy of these entries. Android Back closes it before anything else.
 */
@Composable
fun PlacesMenu(current: Route, onOpen: (Route) -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    IconButton(onClick = { expanded = true }, modifier = Modifier.size(48.dp).testTag("menu.button")) {
        Icon(Icons.Default.Menu, contentDescription = "Menu")
    }
    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
        listOf(
            Triple(Route.Sessions, "Chats", "menu.chats"),
            Triple(Route.Agents, "Agents", "menu.agents"),
            Triple(Route.Settings, "Settings", "menu.settings"),
        ).forEach { (place, label, tag) ->
            val selected = place == current
            DropdownMenuItem(
                text = { Text(label, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal) },
                trailingIcon = { if (selected) Icon(Icons.Default.Check, contentDescription = "Current place") },
                onClick = {
                    expanded = false
                    if (!selected) onOpen(place)
                },
                modifier = Modifier.testTag(tag),
            )
        }
    }
}
