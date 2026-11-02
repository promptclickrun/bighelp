package app.bighelp.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.clickable
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.bighelp.android.live.LiveModel
import app.bighelp.hermes.chat.ConversationRef
import app.bighelp.hermes.chat.ConversationState
import app.bighelp.hermes.chat.ModelChange
import app.bighelp.hermes.chat.ModelOptions
import kotlinx.coroutines.launch

/** The levels offered for reasoning. The host decides which ones a model really takes and says so if not. */
private val ReasoningLevels = listOf("" to "Auto", "low" to "Low", "medium" to "Medium", "high" to "High")

private class ModelPick(val model: String, val provider: String, val message: String)

/**
 * The chat's own model, reasoning and speed, read back from its live session, and the host's list of choices.
 * A change is shown as done only when the session reports it; a host that wants a yes first, or that queues
 * the change for the next turn, says so here instead of the app pretending.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ModelSheet(live: LiveModel<*>, ref: ConversationRef, state: ConversationState, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var options by remember { mutableStateOf<ModelOptions?>(null) }
    var failed by remember { mutableStateOf(false) }
    var reload by remember { mutableIntStateOf(0) }
    var confirm by remember { mutableStateOf<ModelPick?>(null) }
    var info by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(reload) {
        val read = live.modelOptions(ref)
        options = read
        failed = read == null
    }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp).testTag("sheet.model"), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Model and speed", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            val current = options
            when {
                current != null -> {
                    Text(
                        "Using ${current.model}" + (current.provider?.let { " from $it" } ?: ""),
                        style = MaterialTheme.typography.bodyLarge, modifier = Modifier.testTag("sheet.model.current"),
                    )
                    info?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("sheet.model.info")) }
                    if (current.running || state.running) {
                        Text("A turn is running. The host may start a new model with the next turn.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    SectionLabel("Reasoning")
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        ReasoningLevels.forEach { (level, label) ->
                            FilterChip(
                                selected = current.reasoningEffort.equals(level, ignoreCase = true),
                                onClick = { scope.launch { live.setReasoning(ref, level); reload++ } },
                                label = { Text(label) },
                                modifier = Modifier.heightIn(min = 48.dp).testTag("sheet.reasoning.${level.ifEmpty { "auto" }}"),
                            )
                        }
                    }
                    current.isFast?.let { fast ->
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 52.dp)
                                .toggleable(value = fast, role = Role.Switch, onValueChange = { scope.launch { live.setFast(ref, it); reload++ } })
                                .testTag("sheet.fast"),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("Fast mode", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                            Switch(
                                checked = fast, onCheckedChange = null,
                                colors = SwitchDefaults.colors(checkedTrackColor = Bighelp.colors.switchOn, checkedThumbColor = Color.White, checkedBorderColor = Bighelp.colors.switchOn),
                            )
                        }
                    }
                    SectionLabel("Models")
                    val choices = current.providers.flatMap { provider -> provider.models.map { provider to it } }
                    if (choices.isEmpty()) Text("Your computer didn't list other models.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    LazyColumn(Modifier.heightIn(max = 360.dp).testTag("sheet.model.list")) {
                        items(choices, key = { (provider, model) -> provider.id + "\u0000" + model }) { (provider, model) ->
                            val selected = model == current.model && (current.provider == null || current.provider == provider.id)
                            Row(
                                Modifier.fillMaxWidth().heightIn(min = 52.dp)
                                    .clickable {
                                        scope.launch {
                                            when (val result = live.setModel(ref, model, provider.id, confirmed = false)) {
                                                is ModelChange.Confirmed -> { info = null; reload++ }
                                                is ModelChange.NeedsConfirmation -> confirm = ModelPick(model, provider.id, result.message)
                                                is ModelChange.Deferred -> { info = result.message; reload++ }
                                                null -> Unit
                                            }
                                        }
                                    }
                                    .testTag("sheet.model.choice.$model"),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(model, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal, style = MaterialTheme.typography.bodyLarge)
                                    Text(provider.name, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                if (selected) Text("In use", style = MaterialTheme.typography.labelMedium)
                            }
                        }
                    }
                }
                failed -> {
                    Text("Couldn't read the model choices.", style = MaterialTheme.typography.bodyMedium)
                    TextButton(onClick = { failed = false; reload++ }, modifier = Modifier.testTag("sheet.model.retry")) { Text("Try again") }
                }
                else -> Text("Reading what your computer offers…", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = 48.dp).testTag("sheet.model.done")) { Text("Done") }
        }
    }
    confirm?.let { pick ->
        ConfirmDialog(
            "Switch model?", pick.message, "Switch",
            onConfirm = {
                confirm = null
                scope.launch {
                    when (val result = live.setModel(ref, pick.model, pick.provider, confirmed = true)) {
                        is ModelChange.Deferred -> { info = result.message; reload++ }
                        is ModelChange.Confirmed -> { info = null; reload++ }
                        is ModelChange.NeedsConfirmation, null -> Unit
                    }
                }
            },
            onDismiss = { confirm = null }, tag = "dialog.model-confirm",
        )
    }
}
