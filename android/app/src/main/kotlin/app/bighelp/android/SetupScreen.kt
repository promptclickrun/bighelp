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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import app.bighelp.hermes.HermesEndpointException

/**
 * Asks a typed address whether a Hermes computer answers, with the gate details the person may have to give
 * first. A found computer is not a connection: signing in comes next ([onContinue]). Without a live model (the
 * demo alone) it is only the public status check and offers the demo.
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
    live: Boolean = false,
    onAccess: (AccessInput) -> Unit = {},
    onContinue: () -> Unit = {},
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
            if (live) ExtraAccessSection(setup.access, enabled = !checking, onChange = onAccess)

            if (checking) {
                InkButton("Checking…", onClick = {}, tag = "setup.check", enabled = false)
                InkOutlinedButton("Cancel", onCancel, tag = "setup.cancel")
            } else {
                InkButton("Check computer", onCheck, tag = "setup.check", enabled = setup.address.isNotBlank())
            }

            DiscoveryResultCard(setup.discovery, setup.allowPrivateHttp, live = live, onCheck = onCheck, onTryDemo = onTryDemo, onContinue = onContinue)
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
private fun DiscoveryResultCard(
    discovery: DiscoveryState,
    allowPrivateHttp: Boolean,
    live: Boolean,
    onCheck: () -> Unit,
    onTryDemo: () -> Unit,
    onContinue: () -> Unit,
) {
    when (discovery) {
        DiscoveryState.Idle, DiscoveryState.Checking -> Unit

        is DiscoveryState.Refused -> ResultCard(
            title = "Couldn't use this computer",
            body = discovery.message,
            tag = "setup.result.refused",
        ) {
            InkOutlinedButton("Check again", onCheck, tag = "setup.check-again")
        }

        is DiscoveryState.AddressProblem -> ResultCard(
            title = "That address can't be used",
            body = when (discovery.reason) {
                // With the switch already on, the address itself is the problem, so don't send them to the switch.
                HermesEndpointException.Reason.PlaintextNotAllowed ->
                    if (allowPrivateHttp) {
                        "Plain http:// works only for an address inside your own network, like " +
                            "192.168.1.20, and this one is not. Use https:// instead."
                    } else {
                        "Plain http:// works only inside your own network. Turn on the private network " +
                            "switch for an address like 192.168.1.20, or use https://."
                    }
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
                if (live) append("\n\nNext, choose how to sign in. Nothing has been sent but the check.")
                else append("\n\nThis is not a connection. This build only checked that a computer answers.")
            },
            tag = "setup.result.found",
        ) {
            if (live) InkButton("Sign in", onContinue, tag = "setup.sign-in")
            InkOutlinedButton("Check again", onCheck, tag = "setup.check-again")
            if (!live) InkButton("Try the demo meanwhile", onTryDemo, tag = "setup.demo")
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
        // The card appears or changes after a check; polite means a screen reader announces it without interrupting.
        modifier = Modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite }.testTag(tag),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            actions()
        }
    }
}

/**
 * What guards the address before Hermes does: a Cloudflare Access token, a proxy login, and any custom headers
 * a proxy wants. Closed by default; needed only when the check says the access details were refused.
 */
@Composable
private fun ExtraAccessSection(access: AccessInput, enabled: Boolean, onChange: (AccessInput) -> Unit) {
    var open by rememberSaveable { mutableStateOf(access.kind != AccessKind.None || access.headers.isNotEmpty()) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TextButton(onClick = { open = !open }, modifier = Modifier.testTag("setup.access-toggle")) {
            Text(if (open) "Hide extra access details" else "Extra access details (optional)")
        }
        if (!open) return
        Text(
            "Only if something in front of your computer asks for it, like a company login or a Cloudflare access token. These are kept on this phone, sealed, and sent only to this address.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        listOf(AccessKind.None to "None", AccessKind.Cloudflare to "Cloudflare access token", AccessKind.ProxyLogin to "Username and password").forEach { (kind, label) ->
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .selectable(selected = access.kind == kind, enabled = enabled, role = Role.RadioButton, onClick = { onChange(access.copy(kind = kind)) })
                    .testTag("setup.access.${kind.name}"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = access.kind == kind, onClick = null, enabled = enabled, modifier = Modifier.padding(horizontal = 12.dp))
                Text(label)
            }
        }
        if (access.kind != AccessKind.None) {
            OutlinedTextField(
                value = access.id, onValueChange = { onChange(access.copy(id = it)) }, enabled = enabled, singleLine = true,
                label = { Text(if (access.kind == AccessKind.Cloudflare) "Client ID" else "Username") }, shape = RoundedCornerShape(16.dp),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, capitalization = KeyboardCapitalization.None),
                modifier = Modifier.fillMaxWidth().testTag("setup.access.id"),
            )
            OutlinedTextField(
                value = access.secret, onValueChange = { onChange(access.copy(secret = it)) }, enabled = enabled, singleLine = true,
                label = { Text(if (access.kind == AccessKind.Cloudflare) "Client secret" else "Password") }, shape = RoundedCornerShape(16.dp),
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password),
                modifier = Modifier.fillMaxWidth().testTag("setup.access.secret"),
            )
        }
        SectionLabel("Custom headers")
        access.headers.forEachIndexed { index, (name, value) ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = name, onValueChange = { onChange(access.copy(headers = access.headers.toMutableList().also { list -> list[index] = it to value })) },
                    enabled = enabled, singleLine = true, label = { Text("Name") }, shape = RoundedCornerShape(16.dp),
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, capitalization = KeyboardCapitalization.None),
                    modifier = Modifier.weight(1f).testTag("setup.access.header-name.$index"),
                )
                OutlinedTextField(
                    value = value, onValueChange = { onChange(access.copy(headers = access.headers.toMutableList().also { list -> list[index] = name to it })) },
                    enabled = enabled, singleLine = true, label = { Text("Value") }, shape = RoundedCornerShape(16.dp),
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, capitalization = KeyboardCapitalization.None),
                    modifier = Modifier.weight(1f).testTag("setup.access.header-value.$index"),
                )
                TextButton(onClick = { onChange(access.copy(headers = access.headers.filterIndexed { i, _ -> i != index })) }, enabled = enabled, modifier = Modifier.testTag("setup.access.header-remove.$index")) { Text("Remove") }
            }
        }
        if (access.headers.size < 16) {
            TextButton(onClick = { onChange(access.copy(headers = access.headers + ("" to ""))) }, enabled = enabled, modifier = Modifier.testTag("setup.access.header-add")) { Text("Add a header") }
        }
    }
}
