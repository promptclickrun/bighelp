package app.bighelp.android

import android.animation.ValueAnimator
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/**
 * A demo chat. The reader owns the scroll position: nothing moves it while they read history, Send always
 * brings the newest message into view, and a Latest button appears, in its own row above the message box,
 * whenever they are away from the end.
 * Rows are keyed by message ID, so a row's identity survives every change to the list.
 */
@Composable
fun ChatScreen(
    demo: DemoState,
    sessionId: String,
    onBack: () -> Unit,
    onDraft: (String) -> Unit,
    onSend: () -> Boolean,
) {
    val session = demo.session(sessionId)
    if (session == null) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().testTag("screen.chat.missing")) {
            ScreenHeader("Chat", leading = { BackButton(onBack) })
            Text("This chat isn't available any more.", modifier = Modifier.padding(24.dp))
        }
        return
    }
    val agent = demo.agent(session.agentId)
    val messages = session.messages
    val scope = rememberCoroutineScope()
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = messages.lastIndex.coerceAtLeast(0))
    val lastIndex by rememberUpdatedState(messages.lastIndex)

    // True while the reader is at the end. Only a finished scroll changes it, so a viewport that shrinks
    // (the keyboard opening) never counts as the reader leaving the end. Saved, so rotation keeps it.
    var followTail by rememberSaveable { mutableStateOf(true) }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            if (!scrolling) followTail = !listState.canScrollForward
        }
    }
    // Sending (the only way this list grows) always shows the new messages, even from older history.
    val lastId = messages.lastOrNull()?.id
    var shownLastId by rememberSaveable { mutableStateOf(lastId) }
    LaunchedEffect(lastId) {
        if (lastId != shownLastId) {
            shownLastId = lastId
            followTail = true
            listState.scrollToLatest(lastIndex, animated = ValueAnimator.areAnimatorsEnabled())
        }
    }
    // Keep the end in view when the keyboard opens or closes, but only for a reader who is at the end.
    // Never while a scroll runs: a drag or fling is the reader's, and a programmatic scroll would fight it.
    LaunchedEffect(listState) {
        snapshotFlow { listState.layoutInfo.viewportSize.height }.collect {
            if (followTail && !listState.isScrollInProgress && lastIndex >= 0) {
                listState.scrollToLatest(lastIndex, animated = false)
            }
        }
    }
    // The Latest row takes its own height out of the transcript, so it must never be what moves the reader.
    // It appears only once a finished scroll has left the end (followTail is already false then, so the
    // viewport follow above skips the shrink) and goes away when the reader is back at the end.
    val showLatest by remember { derivedStateOf { !followTail && listState.canScrollForward } }

    Column(Modifier.fillMaxSize().safeDrawingPadding().testTag("screen.chat")) {
        ChatHeader(session.title, agent, onBack)
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.weight(1f).fillMaxWidth().testTag("chat.messages"),
        ) {
            if (messages.isEmpty()) {
                item(key = "empty") { EmptyChatNote(agent) }
            }
            items(messages, key = { it.id }) { message -> MessageRow(message) }
        }
        if (showLatest) {
            // Its own row between the transcript and the message box, so the button covers no message.
            Box(Modifier.fillMaxWidth().padding(vertical = 4.dp), contentAlignment = Alignment.Center) {
                JumpToLatest(
                    onClick = {
                        followTail = true
                        scope.launch { listState.scrollToLatest(lastIndex, animated = ValueAnimator.areAnimatorsEnabled()) }
                    },
                )
            }
        }
        // Keyed by chat, so a draft is read once when the chat opens and then owned by the box while typing.
        Composer(
            key = session.id,
            initialDraft = demo.drafts[session.id].orEmpty(),
            agentName = agent.name,
            onDraft = onDraft,
            onSend = onSend,
        )
    }
}

/** Shows the end of the newest message, even a tall one, not only its start. */
private suspend fun LazyListState.scrollToLatest(lastIndex: Int, animated: Boolean) {
    if (lastIndex < 0) return
    if (animated) animateScrollToItem(lastIndex) else scrollToItem(lastIndex)
    if (canScrollForward) scrollBy(TALL_MESSAGE_PIXELS)
}

private const val TALL_MESSAGE_PIXELS = 100_000f

@Composable
private fun ChatHeader(title: String, agent: DemoAgent, onBack: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BackButton(onBack)
        AgentAvatar(agent, size = 36.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.testTag("chat.title"),
            )
            Text(
                "${agent.name} · demo, sample data",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.testTag("chat.subtitle"),
            )
        }
    }
}

@Composable
private fun EmptyChatNote(agent: DemoAgent) {
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag("chat.empty"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Say hello to ${agent.name}", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        Text(
            "This is a demo: replies are fixed examples, and nothing you type leaves this phone.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun MessageRow(message: DemoMessage) {
    val fromUser = message.fromUser
    Row(
        Modifier.fillMaxWidth().testTag("chat.message.${message.id}"),
        horizontalArrangement = if (fromUser) Arrangement.End else Arrangement.Start,
    ) {
        Column(
            Modifier.padding(start = if (fromUser) 48.dp else 0.dp, end = if (fromUser) 0.dp else 48.dp),
            horizontalAlignment = if (fromUser) Alignment.End else Alignment.Start,
        ) {
            if (message.isExample) {
                Text(
                    "Example reply, not from an agent",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 4.dp, bottom = 2.dp),
                )
            }
            Surface(
                color = if (fromUser) Bighelp.colors.userBubble else MaterialTheme.colorScheme.surfaceContainerHigh,
                contentColor = if (fromUser) Bighelp.colors.onUserBubble else MaterialTheme.colorScheme.onSurface,
                shape = RoundedCornerShape(
                    topStart = 20.dp, topEnd = 20.dp,
                    bottomStart = if (fromUser) 20.dp else 6.dp,
                    bottomEnd = if (fromUser) 6.dp else 20.dp,
                ),
                modifier = Modifier.widthIn(max = 560.dp),
            ) {
                SelectionContainer {
                    Text(message.text, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp))
                }
            }
        }
    }
}

@Composable
private fun JumpToLatest(onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onClick,
        color = MaterialTheme.colorScheme.primary,
        contentColor = MaterialTheme.colorScheme.onPrimary,
        shape = RoundedCornerShape(24.dp),
        shadowElevation = 4.dp,
        modifier = modifier.heightIn(min = 48.dp).testTag("chat.jump-to-latest"),
    ) {
        Row(Modifier.padding(start = 12.dp, end = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.KeyboardArrowDown, contentDescription = null)
            Spacer(Modifier.width(4.dp))
            Text("Latest", style = MaterialTheme.typography.labelLarge)
        }
    }
}

/**
 * The message box. It owns its text while the chat is open and reports every change to the model, which
 * keeps the draft for when the person comes back. Send sits beside the box, never inside a crowded row.
 */
@Composable
private fun Composer(
    key: String,
    initialDraft: String,
    agentName: String,
    onDraft: (String) -> Unit,
    onSend: () -> Boolean,
) {
    var value by remember(key) { mutableStateOf(TextFieldValue(initialDraft, TextRange(initialDraft.length))) }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        OutlinedTextField(
            value = value,
            onValueChange = {
                value = it
                onDraft(it.text)
            },
            placeholder = { Text("Message $agentName") },
            maxLines = 6,
            shape = RoundedCornerShape(26.dp),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            modifier = Modifier.weight(1f).testTag("chat.composer"),
        )
        FilledIconButton(
            onClick = { if (onSend()) value = TextFieldValue("") },
            enabled = value.text.isNotBlank(),
            colors = IconButtonDefaults.filledIconButtonColors(),
            modifier = Modifier.padding(bottom = 4.dp).size(52.dp).testTag("chat.send"),
        ) {
            Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send")
        }
    }
}
