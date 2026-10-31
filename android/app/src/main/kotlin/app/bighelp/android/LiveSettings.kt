package app.bighelp.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.bighelp.android.live.ComputerConnectionState
import app.bighelp.android.live.ComputerLink
import app.bighelp.android.live.ComputerPhase
import app.bighelp.android.live.LiveModel
import app.bighelp.android.live.SavedComputer
import java.util.UUID

/** One line saying where a saved computer stands, from the connection itself and nothing else. */
private fun statusOf(computer: SavedComputer, connection: ComputerConnectionState, link: ComputerLink?): String = when {
    !computer.setupComplete -> "Sign-in not finished"
    computer.id != connection.selectedID -> "Saved"
    connection.phase == ComputerPhase.SignInRequired -> "Sign in again"
    connection.phase == ComputerPhase.Connecting || connection.phase == ComputerPhase.Loading -> "Connecting…"
    connection.phase == ComputerPhase.Failed -> "Couldn't connect"
    connection.phase == ComputerPhase.Connected -> when (link) {
        ComputerLink.Connected -> "Connected"
        ComputerLink.Reconnecting -> "Reconnecting…"
        ComputerLink.Offline -> "Not connected"
        ComputerLink.SignInRequired -> "Sign in again"
        ComputerLink.Connecting, null -> "Connecting…"
    }
    else -> "Saved"
}

/** Saved computers with what can be done with each. Used by Welcome (to open one) and Settings (to manage them). */
@Composable
internal fun SavedComputersCard(
    live: LiveModel<*>,
    onSignInAgain: (UUID) -> Unit,
    modifier: Modifier = Modifier,
    manage: Boolean = false,
) {
    val connection by live.connections.state.collectAsStateWithLifecycle()
    val link by live.link.collectAsStateWithLifecycle()
    var removing by remember { mutableStateOf<SavedComputer?>(null) }
    if (connection.computers.isEmpty()) return
    Column(modifier.fillMaxWidth().testTag("computers.list"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        connection.computers.forEach { computer ->
            val isOpen = computer.id == connection.selectedID && connection.phase == ComputerPhase.Connected
            Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth().testTag("computers.row.${computer.id}")) {
                Column(Modifier.padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 4.dp)) {
                    Text(computer.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(computer.endpoint.canonical, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(statusOf(computer, connection, link), style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 2.dp).testTag("computers.status.${computer.id}"))
                    Row {
                        if (!isOpen && computer.setupComplete) {
                            TextButton(onClick = { live.select(computer.id) }, modifier = Modifier.heightIn(min = 48.dp).testTag("computers.open.${computer.id}")) { Text("Open") }
                        }
                        if (!computer.setupComplete || connection.phase == ComputerPhase.SignInRequired && computer.id == connection.selectedID) {
                            TextButton(onClick = { onSignInAgain(computer.id) }, modifier = Modifier.heightIn(min = 48.dp).testTag("computers.sign-in.${computer.id}")) { Text("Sign in") }
                        }
                        if (manage) {
                            TextButton(onClick = { removing = computer }, modifier = Modifier.heightIn(min = 48.dp).testTag("computers.remove.${computer.id}")) { Text("Remove") }
                        }
                    }
                }
            }
        }
    }
    removing?.let { computer ->
        ConfirmDialog(
            "Remove ${computer.name}?",
            "Its sign-in, access details and chats saved on this phone are deleted. Nothing is deleted on the computer itself.",
            "Remove", { removing = null; live.remove(computer.id) }, { removing = null }, "dialog.remove-computer",
        )
    }
}

/** What Settings shows only while a real computer is open: its computers, the person's name and Nerd Mode. */
@Composable
internal fun ColumnScope.LiveSettingsSections(model: BighelpAppModel, live: LiveModel<*>, state: AppState) {
    val connection by live.connections.state.collectAsStateWithLifecycle()
    val link by live.link.collectAsStateWithLifecycle()
    val chat by live.chat.collectAsStateWithLifecycle()
    SectionLabel("Computers")
    SavedComputersCard(live, onSignInAgain = model::signInAgain, manage = true)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        TextButton(onClick = model::connectComputer, modifier = Modifier.heightIn(min = 48.dp).testTag("settings.add-computer")) { Text("Add a computer") }
        if (connection.phase == ComputerPhase.Connected) {
            TextButton(onClick = { live.disconnect() }, modifier = Modifier.heightIn(min = 48.dp).testTag("settings.disconnect")) { Text("Close this computer") }
        }
    }

    Spacer(Modifier.height(16.dp))
    SectionLabel("You")
    NameField(state.userName, model::setUserName)
    Text(
        "Saved on this phone. It isn't sent to your computer yet.",
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 4.dp),
    )

    Spacer(Modifier.height(16.dp))
    SectionLabel("Advanced")
    Row(
        Modifier.fillMaxWidth().heightIn(min = 52.dp).toggleable(value = state.nerdMode, role = Role.Switch, onValueChange = model::setNerdMode).testTag("settings.nerd-mode"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f).padding(horizontal = 4.dp)) {
            Text("Nerd Mode", style = MaterialTheme.typography.bodyLarge)
            Text("Shows connection details for your computer.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(
            checked = state.nerdMode, onCheckedChange = null,
            colors = SwitchDefaults.colors(checkedTrackColor = Bighelp.colors.switchOn, checkedThumbColor = Color.White, checkedBorderColor = Bighelp.colors.switchOn),
        )
    }
    if (state.nerdMode) {
        val status = chat?.connection?.collectAsStateWithLifecycle()?.value
        val active = connection.computers.firstOrNull { it.id == connection.selectedID }
        Column(Modifier.fillMaxWidth().padding(horizontal = 4.dp).testTag("settings.connection-details"), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Detail("Address", active?.endpoint?.canonical ?: "None open")
            Detail("Link", link?.name ?: "None")
            Detail("Socket", status?.let { "${it.gateway.name}, number ${it.generation}" } ?: "None")
            Detail("One writer per chat", when (status?.exclusiveSubmit) { true -> "Guaranteed by your computer"; false -> "Not guaranteed, sending is off"; null -> "Not known yet" })
            status?.lastFailure?.let { Detail("Last problem", app.bighelp.android.live.LiveText.describe(it)) }
        }
        TextButton(onClick = live::reconnectNow, modifier = Modifier.heightIn(min = 48.dp).testTag("settings.reconnect")) { Text("Reconnect now") }
    }
    Spacer(Modifier.height(8.dp))
    HorizontalDivider()
    Spacer(Modifier.height(8.dp))
}

@Composable
private fun Detail(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(0.4f))
        Text(value, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(0.6f))
    }
}

/** The text is the person's until they finish: it is saved on Done or when the box loses focus, not on every key. */
@Composable
private fun NameField(saved: String, onSave: (String) -> Unit) {
    var text by remember(saved) { mutableStateOf(saved) }
    OutlinedTextField(
        value = text, onValueChange = { text = it.take(MAXIMUM_TYPED_NAME) },
        label = { Text("Your name") }, singleLine = true, shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { onSave(text) }),
        modifier = Modifier.fillMaxWidth().onFocusChanged { if (!it.isFocused) onSave(text) }.testTag("settings.name"),
    )
}

private const val MAXIMUM_TYPED_NAME = 60
