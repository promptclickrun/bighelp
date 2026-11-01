package app.bighelp.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.bighelp.android.live.ChatRow
import app.bighelp.android.live.LiveModel
import app.bighelp.android.live.LiveText
import app.bighelp.android.live.SendOutcome
import app.bighelp.android.live.TranscriptRows
import app.bighelp.hermes.chat.ActivityItem
import app.bighelp.hermes.chat.ActivityKind
import app.bighelp.hermes.chat.ActivityLifecycle
import app.bighelp.hermes.chat.ApprovalChoice
import app.bighelp.hermes.chat.ConversationRef
import app.bighelp.hermes.chat.ConversationState
import app.bighelp.hermes.chat.ItemOrigin
import app.bighelp.hermes.chat.MessageItem
import app.bighelp.hermes.chat.MessageRole
import app.bighelp.hermes.chat.PromptAnswer
import app.bighelp.hermes.chat.PromptContent
import app.bighelp.hermes.chat.PromptState
import app.bighelp.hermes.chat.ReviewDecision
import app.bighelp.hermes.chat.SecureKind
import app.bighelp.hermes.chat.SendMode
import app.bighelp.hermes.chat.SlashCommand
import app.bighelp.hermes.chat.UnresolvedSubmission
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

/**
 * A real chat: the shared [ChatPage] with the host's transcript, tools and reasoning as they happened, the
 * agent's questions above the message box, and a message box that steers a running turn by default. Everything
 * shown comes from the chat's own state; nothing is invented while it opens or runs.
 */
@Composable
internal fun LiveChatScreen(
    live: LiveModel<*>,
    refId: String,
    onBack: () -> Unit,
    onOpenChat: (ConversationRef) -> Unit,
    onSignInAgain: () -> Unit,
) {
    val ref = remember(refId) { ConversationRef.parse(refId) }
    if (ref == null) {
        Column(Modifier.fillMaxWidth().testTag("screen.chat.missing")) {
            ScreenHeader("Chat", leading = { BackButton(onBack) })
            Text("This chat isn't available any more.", modifier = Modifier.padding(24.dp))
        }
        return
    }
    val conversations by live.conversations.collectAsStateWithLifecycle()
    val catalog by live.catalog.collectAsStateWithLifecycle()
    val link by live.link.collectAsStateWithLifecycle()
    val problem by live.reconnectProblem.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val state = conversations[ref]
    val summary = catalog.sessions.firstOrNull { it.ref == ref }
    val agentName = catalog.agents.firstOrNull { it.id == ref.profile }?.displayName?.ifBlank { null } ?: ref.profile
    val title = state?.title?.takeIf { it.isNotBlank() } ?: summary?.title?.ifBlank { null } ?: if (summary?.isCanonicalBotChat == true) "Bot Chat" else "Chat"
    var sheet by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var archiving by remember { mutableStateOf(false) }

    val rows = remember(state) { state?.let(TranscriptRows::withEdges).orEmpty() }
    val tail = rows.lastOrNull()
    ChatPage(
        rows = rows,
        rowKey = ChatRow::key,
        tailVersion = Pair((tail as? ChatRow.Message)?.item?.text?.length, tail?.key),
        onReachTop = {
            val history = state?.history
            if (history != null && history.hasOlder && !history.loadingOlder) scope.launch { live.loadOlder(ref) }
        },
        header = {
            Column {
                LiveChatHeader(
                    title = title, agentName = agentName, profile = ref.profile, model = state?.runtime?.model,
                    onBack = onBack,
                    onModel = { sheet = true }, onRename = { renaming = true }, onArchive = { archiving = true },
                    onBranch = {
                        val row = state?.items?.lastOrNull { it is MessageItem && it.rowId != null && it.origin == ItemOrigin.Saved } as? MessageItem
                        if (row?.rowId == null) live.notify("Branch needs a saved message first.")
                        else scope.launch { live.fork(ref, row.rowId!!)?.let(onOpenChat) }
                    },
                )
                LinkBanner(link, problem, onReconnect = live::reconnectNow, onSignInAgain = onSignInAgain, modifier = Modifier.padding(horizontal = 12.dp))
            }
        },
        empty = {
            if (state == null) Text("Opening this chat…", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(8.dp).testTag("chat.opening"))
            else EmptyChatNote("Say hello to $agentName", "Replies come from $agentName on your computer.")
        },
        bottomBar = { if (state != null) LiveBottomBar(live, ref, state, agentName) },
    ) { row ->
        when (row) {
            is ChatRow.Message -> LiveMessage(row.item)
            is ChatRow.Activity -> ActivityRow(row.item)
            is ChatRow.Note -> Text(
                row.text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).testTag("chat.note.${row.key}"),
            )
            is ChatRow.History -> TextButton(
                onClick = { scope.launch { live.loadOlder(ref) } }, enabled = !row.loading,
                modifier = Modifier.fillMaxWidth().testTag("chat.older"),
            ) { Text(if (row.loading) "Loading earlier messages…" else "Load earlier messages") }
            is ChatRow.Working -> Text(
                row.label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 4.dp).semantics { liveRegion = LiveRegionMode.Polite }.testTag("chat.working"),
            )
        }
    }
    if (sheet && state != null) ModelSheet(live, ref, state, onDismiss = { sheet = false })
    if (renaming) TextEntryDialog("Rename chat", title, "Rename", { name -> renaming = false; scope.launch { live.rename(ref, name) } }, { renaming = false }, "dialog.rename")
    if (archiving) ConfirmDialog(
        "Archive this chat?", "It leaves the list and stays in Archived chats. You can restore it.", "Archive",
        { archiving = false; scope.launch { live.archive(ref); onBack() } }, { archiving = false }, "dialog.archive",
    )
}

@Composable
private fun LiveChatHeader(
    title: String, agentName: String, profile: String, model: String?,
    onBack: () -> Unit, onModel: () -> Unit, onRename: () -> Unit, onBranch: () -> Unit, onArchive: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        BackButton(onBack)
        LiveAvatar(agentName, profile, size = 36.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.testTag("chat.title"))
            Text(
                listOfNotNull(agentName, model).joinToString(" · "), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.testTag("chat.subtitle"),
            )
        }
        Box {
            IconButton(onClick = { menu = true }, modifier = Modifier.size(48.dp).testTag("chat.more")) { Icon(Icons.Default.MoreVert, contentDescription = "Chat options") }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Model and speed") }, onClick = { menu = false; onModel() }, modifier = Modifier.testTag("chat.menu.model"))
                DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; onRename() }, modifier = Modifier.testTag("chat.menu.rename"))
                DropdownMenuItem(text = { Text("Branch this chat") }, onClick = { menu = false; onBranch() }, modifier = Modifier.testTag("chat.menu.branch"))
                DropdownMenuItem(text = { Text("Archive") }, onClick = { menu = false; onArchive() }, modifier = Modifier.testTag("chat.menu.archive"))
            }
        }
    }
}

@Composable
internal fun EmptyChatNote(title: String, body: String) {
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag("chat.empty"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// ---- messages and activity ----------------------------------------------------------------------------

@Composable
private fun LiveMessage(item: MessageItem) {
    val fromUser = item.role == MessageRole.User
    MessageBubble(fromUser = fromUser, modifier = Modifier.testTag("chat.message.${item.id}")) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (item.text.isNotEmpty()) {
                // The person's own words are shown as typed; only an agent's reply is read as Markdown.
                if (fromUser) Text(item.text, style = MaterialTheme.typography.bodyLarge) else MarkdownText(item.text)
            }
            if (item.hasUnsupportedContent) {
                Text("This message has content the app can't show yet.", style = MaterialTheme.typography.bodySmall, fontStyle = FontStyle.Italic)
            }
            item.failure?.let { failure ->
                Text(
                    if (failure.retryable) "This reply stopped before it finished. You can ask again." else "This reply stopped before it finished.",
                    style = MaterialTheme.typography.bodySmall, fontStyle = FontStyle.Italic,
                )
            }
        }
    }
}

/** An agent's reply, with its code, headings, lists and bold, italic and code marks drawn. Text stays selectable. */
@Composable
internal fun MarkdownText(text: String) {
    val codeBackground = MaterialTheme.colorScheme.surfaceContainerHighest
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (block in Markdown.blocks(text)) when (block) {
            is MdBlock.Paragraph -> Text(inline(block.text, codeBackground), style = MaterialTheme.typography.bodyLarge)
            is MdBlock.Heading -> Text(inline(block.text, codeBackground), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            is MdBlock.Bullets -> Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                block.items.forEachIndexed { index, item ->
                    Row {
                        Text(if (block.ordered) "${index + 1}." else "•", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.width(24.dp))
                        Text(inline(item, codeBackground), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                    }
                }
            }
            is MdBlock.Code -> Surface(color = codeBackground, shape = RoundedCornerShape(10.dp), modifier = Modifier.fillMaxWidth()) {
                Text(
                    block.text, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.horizontalScroll(rememberScrollState()).padding(10.dp),
                )
            }
        }
    }
}

private fun inline(text: String, codeBackground: androidx.compose.ui.graphics.Color): AnnotatedString = buildAnnotatedString {
    for (span in Markdown.spans(text)) {
        val style = SpanStyle(
            fontWeight = if (span.bold) FontWeight.Bold else null,
            fontStyle = if (span.italic) FontStyle.Italic else null,
            fontFamily = if (span.code) FontFamily.Monospace else null,
            background = if (span.code) codeBackground else androidx.compose.ui.graphics.Color.Unspecified,
        )
        withStyle(style) { append(span.text) }
    }
}

@Composable
private fun ActivityRow(item: ActivityItem) {
    var open by remember(item.id) { mutableStateOf(false) }
    val state = when (item.lifecycle) {
        ActivityLifecycle.Running -> "Running"
        ActivityLifecycle.Succeeded -> "Done"
        ActivityLifecycle.Failed -> "Failed"
        ActivityLifecycle.Cancelled -> "Stopped"
        ActivityLifecycle.Recorded -> ""
    }
    val details = listOfNotNull(item.detail, item.arguments?.let { "Input: $it" }, item.result?.let { "Result: $it" }).filter { it.isNotBlank() }
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer, shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth().testTag("chat.activity.${item.id}"),
    ) {
        Column(Modifier.clickable(enabled = details.isNotEmpty()) { open = !open }.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (item.kind == ActivityKind.Reasoning) "Thinking" else item.title,
                    style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                )
                if (state.isNotEmpty()) Text(state, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (open) for (detail in details) {
                Text(
                    detail.take(MAXIMUM_DETAIL), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 6.dp),
                )
            }
        }
    }
}

private const val MAXIMUM_DETAIL = 4_000

// ---- the box and what sits above it ---------------------------------------------------------------------

@Composable
private fun LiveBottomBar(live: LiveModel<*>, ref: ConversationRef, state: ConversationState, agentName: String) {
    val scope = rememberCoroutineScope()
    Column {
        if (state.legacyPromptHost) {
            // This host answers questions the older way: no card can be shown, so say so rather than look broken.
            Text(
                "Your computer can't show this agent's questions in the app yet. You may need to update the plugin on your computer.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp).testTag("chat.legacy-prompts"),
            )
        }
        state.unresolved.forEach { entry ->
            UnresolvedCard(
                entry,
                onPutBack = { scope.launch { live.review(ref, entry.id, ReviewDecision.RestoreToComposer) } },
                onDiscard = { scope.launch { live.review(ref, entry.id, ReviewDecision.Discard) } },
            )
        }
        state.prompts.forEach { prompt ->
            PromptCard(
                prompt,
                onAnswer = { answer -> scope.launch { live.answerPrompt(prompt.id, answer) } },
                onDecline = { scope.launch { live.declinePrompt(prompt.id) } },
            )
        }
        LiveComposer(live, ref, state, agentName)
    }
}

@Composable
private fun UnresolvedCard(entry: UnresolvedSubmission, onPutBack: () -> Unit, onDiscard: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh, shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("chat.unresolved.${entry.id}"),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                if (entry.rejectionCode == null) "We couldn't confirm this message was sent." else "Your computer didn't take this message.",
                style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
            )
            Text(entry.composerText, maxLines = 3, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (entry.rejectionCode == null) Text("It is never sent again by itself. Check the chat before you try again.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row {
                TextButton(onClick = onPutBack, modifier = Modifier.heightIn(min = 48.dp).testTag("chat.unresolved.restore")) { Text("Put it back in the box") }
                TextButton(onClick = onDiscard, modifier = Modifier.heightIn(min = 48.dp).testTag("chat.unresolved.discard")) { Text("Discard") }
            }
        }
    }
}

@Composable
private fun LiveComposer(live: LiveModel<*>, ref: ConversationRef, state: ConversationState, agentName: String) {
    val scope = rememberCoroutineScope()
    var value by remember(ref) { mutableStateOf(TextFieldValue(state.draft, TextRange(state.draft.length))) }
    var error by remember(ref) { mutableStateOf<String?>(null) }
    var sending by remember(ref) { mutableStateOf(false) }
    var suggestions by remember(ref) { mutableStateOf<List<SlashCommand>>(emptyList()) }
    // A draft the host returns (a refused send restores it) fills an empty box; a box with text is never overwritten.
    LaunchedEffect(state.draft) {
        if (state.draft.isNotEmpty() && value.text.isEmpty()) value = TextFieldValue(state.draft, TextRange(state.draft.length))
    }
    LaunchedEffect(value.text) {
        suggestions = if (value.text.startsWith("/")) live.suggestions(ref, value.text).take(MAXIMUM_SUGGESTIONS) else emptyList()
    }
    val blocked = state.sendBlock?.let(LiveText::sendBlock)
    val canSend = value.text.isNotBlank() && blocked == null && !sending

    fun submit(mode: SendMode) {
        val text = value.text
        if (text.isBlank() || sending) return
        sending = true
        error = null
        scope.launch {
            when (val outcome = live.send(ref, text, mode)) {
                SendOutcome.Sent -> value = TextFieldValue("")
                is SendOutcome.Kept -> error = outcome.message
            }
            sending = false
        }
    }

    Column(Modifier.fillMaxWidth()) {
        if (suggestions.isNotEmpty()) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp).testTag("chat.suggestions")) {
                suggestions.forEach { command ->
                    TextButton(
                        onClick = { val text = "/${command.name} "; value = TextFieldValue(text, TextRange(text.length)); live.editDraft(ref, text) },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp),
                    ) {
                        Text("/${command.name}", fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.width(8.dp))
                        Text(command.description, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
        val note = error ?: blocked
        if (note != null) {
            Text(
                note, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp).semantics { liveRegion = LiveRegionMode.Polite }.testTag("chat.composer.note"),
            )
        }
        if (state.running) {
            // Send steers the running turn. These are the other choices, kept out of the row with the box.
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = { scope.launch { live.stop(ref) } }, enabled = !state.stopRequested, modifier = Modifier.heightIn(min = 48.dp).testTag("chat.stop")) { Text("Stop") }
                TextButton(onClick = { submit(SendMode.Queue) }, enabled = canSend, modifier = Modifier.heightIn(min = 48.dp).testTag("chat.queue")) { Text("Send next") }
                TextButton(onClick = { submit(SendMode.InterruptAndSend) }, enabled = canSend, modifier = Modifier.heightIn(min = 48.dp).testTag("chat.stop-and-send")) { Text("Stop and send") }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                value = value,
                onValueChange = { value = it; live.editDraft(ref, it.text) },
                readOnly = sending,
                placeholder = { Text(if (state.running) "Steer $agentName" else "Message $agentName") },
                maxLines = 6, shape = RoundedCornerShape(26.dp),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                modifier = Modifier.weight(1f).testTag("chat.composer"),
            )
            FilledIconButton(
                onClick = { submit(SendMode.Default) }, enabled = canSend,
                colors = IconButtonDefaults.filledIconButtonColors(),
                modifier = Modifier.padding(bottom = 4.dp).size(52.dp).testTag("chat.send"),
            ) { Icon(Icons.AutoMirrored.Filled.Send, contentDescription = if (state.running) "Steer" else "Send") }
        }
    }
}

private const val MAXIMUM_SUGGESTIONS = 6

// ---- the agent's questions ------------------------------------------------------------------------------

@Composable
private fun PromptCard(prompt: PromptState, onAnswer: (PromptAnswer) -> Unit, onDecline: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh, shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("chat.prompt.${prompt.id}"),
    ) {
        // Capped, so a long question never pushes the transcript off the screen.
        Column(Modifier.heightIn(max = 300.dp).verticalScroll(rememberScrollState()).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            when (val content = prompt.content) {
                is PromptContent.Approval -> ApprovalBody(content, onAnswer)
                is PromptContent.Clarification -> ClarifyBody(content, onAnswer, onDecline)
                is PromptContent.SecureInput -> SecureBody(content, onAnswer, onDecline)
            }
        }
    }
}

@Composable
private fun ApprovalBody(content: PromptContent.Approval, onAnswer: (PromptAnswer) -> Unit) {
    Text("Your agent wants to run something", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
    content.description?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
    content.command?.let {
        Surface(color = MaterialTheme.colorScheme.surfaceContainerHighest, shape = RoundedCornerShape(10.dp), modifier = Modifier.fillMaxWidth()) {
            Text(it.take(MAXIMUM_DETAIL), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(10.dp))
        }
    }
    content.toolName?.let { Text("Tool: $it", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    // Only the choices the host offered are shown; Deny is always last.
    val ordered = content.choices.sortedBy { if (it == ApprovalChoice.Deny) 1 else 0 }
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.fillMaxWidth()) {
        ordered.forEach { choice ->
            TextButton(onClick = { onAnswer(PromptAnswer.Approve(choice)) }, modifier = Modifier.heightIn(min = 48.dp).testTag("prompt.approve.${choice.wire}")) {
                Text(
                    when (choice) {
                        ApprovalChoice.Once -> "Allow once"
                        ApprovalChoice.Session -> "Allow in this chat"
                        ApprovalChoice.Always -> "Always allow"
                        ApprovalChoice.Deny -> "Don't allow"
                    },
                )
            }
        }
    }
}

@Composable
private fun ClarifyBody(content: PromptContent.Clarification, onAnswer: (PromptAnswer) -> Unit, onDecline: () -> Unit) {
    Text(if (content.questions.size > 1) "Your agent has a few questions" else "Your agent has a question", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
    // One entry per question: the chosen options and typed text. The locked ones are already answered by the host.
    val chosen = remember(content) { mutableStateOf(content.questions.associate { it.id to emptySet<String>() }) }
    val typed = remember(content) { mutableStateOf(content.questions.associate { it.id to "" }) }
    for (question in content.questions) {
        Text(question.question, style = MaterialTheme.typography.bodyLarge)
        if (question.lockedAnswer != null) {
            Text("Answered: ${question.lockedAnswer}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            continue
        }
        question.choices.forEach { choice ->
            val selected = choice in chosen.value.getValue(question.id)
            TextButton(
                onClick = {
                    val now = chosen.value.getValue(question.id)
                    val next = if (question.multiSelect) (if (selected) now - choice else now + choice) else setOf(choice)
                    chosen.value = chosen.value + (question.id to next)
                    if (!question.multiSelect) typed.value = typed.value + (question.id to "")
                },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("prompt.choice.${question.id}.$choice"),
            ) { Text(if (selected) "✓ $choice" else choice, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal, modifier = Modifier.fillMaxWidth()) }
        }
        OutlinedTextField(
            value = typed.value.getValue(question.id),
            onValueChange = { typed.value = typed.value + (question.id to it); if (!question.multiSelect && it.isNotEmpty()) chosen.value = chosen.value + (question.id to emptySet()) },
            label = { Text(if (question.choices.isEmpty()) "Your answer" else "Something else") },
            shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth().testTag("prompt.text.${question.id}"),
        )
    }
    val answers = content.questions.mapNotNull { question ->
        if (question.lockedAnswer != null) return@mapNotNull question.id to question.lockedAnswer!!
        val picked = question.choices.filter { it in chosen.value.getValue(question.id) }
        val extra = typed.value.getValue(question.id).trim()
        val text = when {
            question.multiSelect -> (picked + listOfNotNull(extra.takeIf { it.isNotEmpty() })).takeIf { it.isNotEmpty() }?.let { JsonArray(it.map(::JsonPrimitive)).toString() }
            extra.isNotEmpty() -> extra
            else -> picked.firstOrNull()
        }
        text?.let { question.id to it }
    }.toMap()
    Row {
        TextButton(onClick = { onAnswer(PromptAnswer.Clarify(answers)) }, enabled = answers.size == content.questions.size, modifier = Modifier.heightIn(min = 48.dp).testTag("prompt.clarify.send")) { Text("Send answer") }
        TextButton(onClick = onDecline, modifier = Modifier.heightIn(min = 48.dp).testTag("prompt.clarify.skip")) { Text("Skip") }
    }
}

@Composable
private fun SecureBody(content: PromptContent.SecureInput, onAnswer: (PromptAnswer) -> Unit, onDecline: () -> Unit) {
    var secret by remember(content) { mutableStateOf("") }
    var identifier by remember(content) { mutableStateOf("") }
    val label = content.label ?: content.prompt ?: when (content.kind) {
        SecureKind.Sudo -> "Your agent needs your computer's password"
        SecureKind.VaultCode -> "Your agent needs a code"
        SecureKind.VaultSaveLogin -> "Save a login for your agent?"
        SecureKind.VaultUnlock -> "Your agent needs to unlock its vault"
        SecureKind.Secret -> "Your agent needs a secret"
    }
    Text(label, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
    listOfNotNull(content.site, content.envVar, content.backendName).takeIf { it.isNotEmpty() }?.let {
        Text(it.joinToString(" · "), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    Text("What you type goes to your computer only. It is not put in the chat or saved on this phone.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (content.kind == SecureKind.VaultSaveLogin) {
        OutlinedTextField(identifier, { identifier = it }, label = { Text("Username or email") }, singleLine = true, shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth().testTag("prompt.secure.identifier"))
    }
    OutlinedTextField(
        secret, { secret = it }, label = { Text(if (content.kind == SecureKind.VaultCode) "Code" else "Value") }, singleLine = true,
        visualTransformation = PasswordVisualTransformation(), shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth().testTag("prompt.secure.value"),
    )
    Row {
        TextButton(
            onClick = {
                // The repository clears this array after the one response; the text field's copy is dropped here.
                val value = secret.toCharArray()
                secret = ""
                onAnswer(if (content.kind == SecureKind.VaultSaveLogin) PromptAnswer.SaveLogin(identifier, value) else PromptAnswer.Secure(value))
            },
            enabled = secret.isNotEmpty() && (content.kind != SecureKind.VaultSaveLogin || identifier.isNotBlank()),
            modifier = Modifier.heightIn(min = 48.dp).testTag("prompt.secure.send"),
        ) { Text("Send") }
        TextButton(onClick = { secret = ""; onDecline() }, modifier = Modifier.heightIn(min = 48.dp).testTag("prompt.secure.decline")) { Text("Don't share") }
    }
}
