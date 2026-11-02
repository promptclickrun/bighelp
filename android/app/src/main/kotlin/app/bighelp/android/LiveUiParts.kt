package app.bighelp.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.bighelp.android.live.ComputerLink
import app.bighelp.android.live.LiveModel
import app.bighelp.android.live.LiveText
import app.bighelp.hermes.chat.ChatError

private val AvatarColors = listOf(0xFF2F6FD6, 0xFF1F7A4D, 0xFF8250DF, 0xFFB5532A, 0xFF0F7C8C, 0xFFA33A6B)

/** An agent's picture for a real computer: its first letter on a color fixed by its ID. No status is implied. */
@Composable
internal fun LiveAvatar(name: String, id: String, modifier: Modifier = Modifier, size: Dp = 44.dp) {
    val color = Color(AvatarColors[(id.hashCode() and Int.MAX_VALUE) % AvatarColors.size])
    Box(modifier.size(size).clip(CircleShape).background(color), contentAlignment = Alignment.Center) {
        Text(
            name.trim().take(1).uppercase().ifEmpty { "?" },
            color = Color.White,
            fontWeight = FontWeight.Bold,
            fontSize = (size.value * 0.42f).sp,
        )
    }
}

/**
 * The strip above a live screen when the connection is not simply fine. It states what the gateway reports,
 * and offers the one thing that can help: Reconnect, or signing in again when the host refused the sign-in.
 */
@Composable
internal fun LinkBanner(
    link: ComputerLink?,
    problem: ChatError.Kind?,
    onReconnect: () -> Unit,
    onSignInAgain: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val needsSignIn = problem == ChatError.Kind.SignInRequired || link == ComputerLink.SignInRequired
    val text = if (needsSignIn) LiveText.link(ComputerLink.SignInRequired) else LiveText.link(link)
    if (text == null) return
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = RoundedCornerShape(12.dp),
        modifier = modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite }.testTag("link.banner"),
    ) {
        Row(Modifier.padding(start = 14.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f).padding(vertical = 10.dp))
            when {
                needsSignIn -> TextButton(onClick = onSignInAgain, modifier = Modifier.heightIn(min = 48.dp).testTag("link.sign-in")) { Text("Sign in") }
                link == ComputerLink.Offline -> TextButton(onClick = onReconnect, modifier = Modifier.heightIn(min = 48.dp).testTag("link.reconnect")) { Text("Reconnect") }
                else -> Spacer(Modifier.width(12.dp))
            }
        }
    }
}

/** Shows [LiveModel.notice] as a snackbar, once each. Place it in a Box over the screen. */
@Composable
internal fun NoticeHost(live: LiveModel<*>, modifier: Modifier = Modifier) {
    val notice by live.notice.collectAsStateWithLifecycle()
    val host = remember { SnackbarHostState() }
    LaunchedEffect(notice?.id) {
        val current = notice ?: return@LaunchedEffect
        host.showSnackbar(current.text)
        live.dismissNotice(current.id)
    }
    SnackbarHost(host, modifier.testTag("notice.host"))
}

@Composable
internal fun ConfirmDialog(
    title: String,
    text: String,
    confirm: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    tag: String,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(text) },
        confirmButton = { TextButton(onClick = onConfirm, modifier = Modifier.testTag("$tag.confirm")) { Text(confirm) } },
        dismissButton = { TextButton(onClick = onDismiss, modifier = Modifier.testTag("$tag.cancel")) { Text("Cancel") } },
        modifier = Modifier.testTag(tag),
    )
}

@Composable
internal fun TextEntryDialog(
    title: String,
    initial: String,
    confirm: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
    tag: String,
) {
    var value by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = value,
                onValueChange = { value = it },
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Done),
                modifier = Modifier.fillMaxWidth().testTag("$tag.field"),
            )
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(value.trim()) }, enabled = value.isNotBlank(), modifier = Modifier.testTag("$tag.confirm")) { Text(confirm) }
        },
        dismissButton = { TextButton(onClick = onDismiss, modifier = Modifier.testTag("$tag.cancel")) { Text("Cancel") } },
        modifier = Modifier.testTag(tag),
    )
}

/** A plain message block for an empty list or a failed load, with an optional action. */
@Composable
internal fun EmptyState(title: String, body: String, tag: String, action: (@Composable () -> Unit)? = null) {
    Column(
        Modifier.fillMaxWidth().padding(24.dp).testTag(tag),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        Text(body, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        action?.invoke()
    }
}
