package app.bighelp.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import app.bighelp.android.live.ComputerConnectionState
import app.bighelp.android.live.ComputerPhase
import app.bighelp.android.live.LiveText
import app.bighelp.hermes.AuthStatus
import app.bighelp.hermes.SignInInput

/**
 * Choosing how to sign in to the computer that was just checked, using only what the host itself offered:
 * the dashboard's own session, a password for a password sign-in, a browser sign-in, or a token the person
 * already has. Typed secrets live in plain `remember` state, never in saved state, and are dropped when the
 * screen goes.
 */
@Composable
internal fun SignInScreen(
    connection: ComputerConnectionState,
    defaultName: String,
    onSignIn: (name: String, input: SignInInput) -> Unit,
    onBack: () -> Unit,
) {
    val status = connection.authStatus
    var name by remember(defaultName) { mutableStateOf(defaultName) }
    var waitingForBrowser by remember { mutableStateOf(false) }
    val busy = connection.phase == ComputerPhase.Discovering || connection.phase == ComputerPhase.Connecting
    Column(Modifier.fillMaxSize().safeDrawingPadding().testTag("screen.sign-in")) {
        ScreenHeader("Sign in", leading = { BackButton(onBack) })
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = 520.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Name this computer") },
                    singleLine = true,
                    enabled = !busy,
                    shape = RoundedCornerShape(16.dp),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Next),
                    modifier = Modifier.fillMaxWidth().testTag("signin.name"),
                )
                FailureNote(connection)
                when {
                    busy -> BusyNote(waitingForBrowser, connection.phase)
                    status == null -> Text("Check the computer first.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    else -> {
                        SignInMethods(
                            status = status,
                            onChoose = { input ->
                                waitingForBrowser = input is SignInInput.Browser
                                onSignIn(name, input)
                            },
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

@Composable
private fun FailureNote(connection: ComputerConnectionState) {
    val text = connection.authFailure?.let(LiveText::describe) ?: connection.problem?.let(LiveText::problem)
    if (text == null || connection.phase == ComputerPhase.Discovering || connection.phase == ComputerPhase.Connecting) return
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite }.testTag("signin.failure"),
    ) {
        Text(text, modifier = Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun BusyNote(waitingForBrowser: Boolean, phase: ComputerPhase) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite }.testTag("signin.busy"),
    ) {
        Text(
            when {
                waitingForBrowser && phase == ComputerPhase.Connecting -> "Finish signing in in your browser, then come back here."
                phase == ComputerPhase.Discovering -> "Checking how this computer signs people in…"
                else -> "Connecting…"
            },
            modifier = Modifier.padding(16.dp),
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Composable
private fun SignInMethods(status: AuthStatus, onChoose: (SignInInput) -> Unit) {
    var tokenOpen by remember { mutableStateOf(false) }
    if (!status.authRequired) {
        Text(
            "This computer doesn't ask for a password. bighelp can use its own session.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        InkButton("Connect", { onChoose(SignInInput.Dashboard) }, tag = "signin.dashboard")
    } else {
        val passwordProviders = status.passwordProviders
        if (passwordProviders.isNotEmpty()) PasswordForm(status, onChoose)
        if (status.supportsNativePkce) {
            SectionLabel("Browser")
            if (status.browserProviders.isEmpty()) {
                InkOutlinedButton("Sign in with your browser", { onChoose(SignInInput.Browser(null)) }, tag = "signin.browser")
            } else {
                status.browserProviders.forEach { provider ->
                    InkOutlinedButton("Continue with ${provider.displayName}", { onChoose(SignInInput.Browser(provider.name)) }, tag = "signin.browser.${provider.name}")
                }
            }
        }
        if (passwordProviders.isEmpty() && !status.supportsNativePkce) {
            Text(
                "This computer asks for a sign-in this app can't start by itself. If you have an access token, use it below.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
    TextButton(onClick = { tokenOpen = !tokenOpen }, modifier = Modifier.testTag("signin.token-toggle")) {
        Text(if (tokenOpen) "Hide the token box" else "Use an access token instead")
    }
    if (tokenOpen) TokenForm(onChoose)
}

@Composable
private fun PasswordForm(status: AuthStatus, onChoose: (SignInInput) -> Unit) {
    val providers = status.passwordProviders
    var provider by remember { mutableStateOf(providers.firstOrNull()?.name) }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    SectionLabel("Password")
    if (providers.size > 1) {
        providers.forEach { option ->
            Row(
                Modifier.fillMaxWidth().heightIn48().selectable(selected = provider == option.name, role = Role.RadioButton, onClick = { provider = option.name }).testTag("signin.provider.${option.name}"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = provider == option.name, onClick = null, modifier = Modifier.padding(horizontal = 12.dp))
                Text(option.displayName)
            }
        }
    }
    OutlinedTextField(
        value = username, onValueChange = { username = it }, label = { Text("Username") }, singleLine = true,
        shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, capitalization = KeyboardCapitalization.None, imeAction = ImeAction.Next),
        modifier = Modifier.fillMaxWidth().testTag("signin.username"),
    )
    OutlinedTextField(
        value = password, onValueChange = { password = it }, label = { Text("Password") }, singleLine = true,
        visualTransformation = PasswordVisualTransformation(), shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
        modifier = Modifier.fillMaxWidth().testTag("signin.password"),
    )
    InkButton(
        "Sign in",
        { onChoose(SignInInput.Password(provider, username, password)); password = "" },
        tag = "signin.password-submit",
        enabled = username.isNotBlank() && password.isNotEmpty(),
    )
}

@Composable
private fun TokenForm(onChoose: (SignInInput) -> Unit) {
    var token by remember { mutableStateOf("") }
    OutlinedTextField(
        value = token, onValueChange = { token = it }, label = { Text("Access token") }, singleLine = true,
        visualTransformation = PasswordVisualTransformation(), shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
        modifier = Modifier.fillMaxWidth().testTag("signin.token"),
    )
    InkButton("Use this token", { onChoose(SignInInput.Token(token.trim())); token = "" }, tag = "signin.token-submit", enabled = token.isNotBlank())
}

private fun Modifier.heightIn48(): Modifier = this.then(Modifier.heightIn(min = 48.dp))
