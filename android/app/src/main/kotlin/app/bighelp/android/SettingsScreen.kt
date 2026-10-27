package app.bighelp.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp

/**
 * The one Settings page: your computers and name (when a real computer is open, through [liveSections]), look,
 * data agreement, the demo, and what this build is. There is no second settings copy anywhere else.
 */
@Composable
fun SettingsScreen(
    appearance: Appearance,
    consentGranted: Boolean,
    versionName: String,
    onAppearance: (Appearance) -> Unit,
    onPrivacyPolicy: () -> Unit,
    onLeaveDemo: () -> Unit,
    onOpenPlace: (Route) -> Unit,
    showDemo: Boolean = true,
    liveSections: (@Composable ColumnScope.() -> Unit)? = null,
) {
    Column(Modifier.fillMaxSize().safeDrawingPadding().testTag("screen.settings")) {
        ScreenHeader("Settings", leading = { PlacesMenu(current = Route.Settings, onOpen = onOpenPlace) })
        if (showDemo) DemoBanner(Modifier.padding(horizontal = 16.dp))
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier
                    .widthIn(max = 520.dp)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                liveSections?.invoke(this)
                SectionLabel("Appearance")
                listOf(
                    Triple(Appearance.Automatic, "Same as phone", "settings.appearance.automatic"),
                    Triple(Appearance.Light, "Light", "settings.appearance.light"),
                    Triple(Appearance.Dark, "Dark", "settings.appearance.dark"),
                ).forEach { (option, label, tag) ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = 52.dp)
                            .selectable(selected = appearance == option, role = Role.RadioButton, onClick = { onAppearance(option) })
                            .testTag(tag),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = appearance == option, onClick = null, modifier = Modifier.padding(horizontal = 12.dp))
                        Text(label, style = MaterialTheme.typography.bodyLarge)
                    }
                }

                Spacer(Modifier.height(16.dp))
                SectionLabel("Your data and AI")
                Text(
                    if (consentGranted) "You agreed to share chat data with your computer and its AI providers."
                    else "Not agreed yet. bighelp asks before it connects to a computer.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp).testTag("settings.consent-status"),
                )
                TextButton(onClick = onPrivacyPolicy, modifier = Modifier.testTag("settings.privacy")) {
                    Text("Privacy policy")
                }

                if (showDemo) {
                    Spacer(Modifier.height(8.dp))
                    HorizontalDivider()
                    Spacer(Modifier.height(8.dp))
                    SectionLabel("Demo")
                    Text(
                        "You are looking at sample chats. Leaving the demo clears them and any unsent drafts.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
                    )
                    InkOutlinedButton("Leave demo", onLeaveDemo, tag = "settings.leave-demo")
                }

                Spacer(Modifier.height(16.dp))
                SectionLabel("About")
                Text(
                    "bighelp for Android $versionName. Chat with your own agents on your Hermes computer. " +
                        "Files, Feed, Projects and the other Hermes tools are not in this build yet.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp).testTag("settings.about"),
                )
            }
        }
    }
}
