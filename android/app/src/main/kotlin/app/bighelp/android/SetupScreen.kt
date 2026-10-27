package app.bighelp.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import app.bighelp.hermes.HermesEndpointException

/**
 * Asks a typed address whether a Hermes computer answers. The result says "found", never "connected":
 * this milestone collects no password or token and opens no chat.
 */
@Composable
fun SetupScreen(
    setup: SetupState,
    onBack: () -> Unit,
    onAddress: (String) -> Unit,
    onAllowPrivateHttp: (Boolean) -> Unit,
    onCheck: () -> Unit,
    onCancel: () -> Unit,
    onTryDemo: () -> Unit,
) {
    val checking = setup.discovery == DiscoveryState.Checking
    Column(Modifier.fillMaxSize().safeDrawingPadding().testTag("screen.setup")) {
        ScreenHeader("Connect your computer", leading = { BackButton(onBack) })
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Column(
            Modifier
                .widthIn(max = 520.dp)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                "Enter the web address of your Hermes computer, the one you open in a browser.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = setup.address,
                onValueChange = onAddress,
                label = { Text("Computer address") },
                placeholder = { Text("hermes.example.com") },
                singleLine = true,
                readOnly = checking,
                shape = RoundedCornerShape(16.dp),
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                    keyboardType = KeyboardType.Uri,
                    imeAction = ImeAction.Go,
                ),
                keyboardActions = KeyboardActions(onGo = { onCheck() }),
                modifier = Modifier.fillMaxWidth().testTag("setup.address"),
            )
            PrivateHttpRow(setup.allowPrivateHttp, enabled = !checking, onChange = onAllowPrivateHttp)

            if (checking) {
                InkButton("Checking…", onClick = {}, tag = "setup.check", enabled = false)
                InkOutlinedButton("Cancel", onCancel, tag = "setup.cancel")
            } else {
                InkButton("Check computer", onCheck, tag = "setup.check", enabled = setup.address.isNotBlank())
            }

            DiscoveryResultCard(setup.discovery, onCheck = onCheck, onTryDemo = onTryDemo)
            Spacer(Modifier.height(8.dp))
        }
        }
    }
}

@Composable
private fun PrivateHttpRow(checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        // The whole row is the switch, so its words are what a screen reader announces.
        Row(
            Modifier
                .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onChange)
                .padding(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 12.dp)
                .testTag("setup.private-http"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f).padding(end = 12.dp)) {
                Text("Private network, plain HTTP", fontWeight = FontWeight.SemiBold)
                Text(
                    "Only for an address inside your home, office, VPN or Tailscale network. Anyone on " +
                        "that network can read plain HTTP traffic.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Switch(
                checked = checked,
                onCheckedChange = null,
                enabled = enabled,
                colors = SwitchDefaults.colors(
                    checkedTrackColor = Bighelp.colors.switchOn,
                    checkedThumbColor = Color.White,
                    checkedBorderColor = Bighelp.colors.switchOn,
                ),
            )
        }
    }
}

@Composable
private fun DiscoveryResultCard(discovery: DiscoveryState, onCheck: () -> Unit, onTryDemo: () -> Unit) {
    when (discovery) {
        DiscoveryState.Idle, DiscoveryState.Checking -> Unit

        is DiscoveryState.AddressProblem -> ResultCard(
            title = "That address can't be used",
            body = when (discovery.reason) {
                HermesEndpointException.Reason.PlaintextNotAllowed ->
                    "Plain http:// works only inside your own network. Turn on the private network " +
                        "switch for an address like 192.168.1.20, or use https://."
                HermesEndpointException.Reason.InvalidEndpoint, HermesEndpointException.Reason.InvalidRoute ->
                    "Use a name or number like hermes.example.com or 192.168.1.20:9119, with no spaces, " +
                        "username, password or question mark."
            },
            tag = "setup.result.problem",
        )

        is DiscoveryState.Unavailable -> ResultCard(
            title = "No Hermes computer answered",
            body = "Nothing usable came back from ${discovery.address}. Check the address, that the " +
                "computer is on, and that this phone can reach it.",
            tag = "setup.result.unavailable",
        ) {
            InkOutlinedButton("Check again", onCheck, tag = "setup.check-again")
        }

        is DiscoveryState.Found -> ResultCard(
            title = "Found a Hermes computer",
            body = buildString {
                append(discovery.address).append("\n\n")
                append(if (discovery.authRequired) "It asks for a sign-in." else "It does not ask for a sign-in.")
                if (discovery.authRequired) {
                    append(if (discovery.browserSignIn) " Browser sign-in is offered." else " Browser sign-in is not offered.")
                }
                append("\n\nThis is not a connection. Signing in and chatting come in a later update; ")
                append("this preview sent no password or chat.")
            },
            tag = "setup.result.found",
        ) {
            InkOutlinedButton("Check again", onCheck, tag = "setup.check-again")
            InkButton("Try the demo meanwhile", onTryDemo, tag = "setup.demo")
        }
    }
}

@Composable
private fun ResultCard(
    title: String,
    body: String,
    tag: String,
    actions: @Composable () -> Unit = {},
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth().testTag(tag),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            actions()
        }
    }
}
