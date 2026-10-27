package app.bighelp.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * The whole app: observes [BighelpAppModel] and shows its current route. Screens only call the model's
 * actions; they hold no navigation or demo state of their own except scroll position and the message box.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun BighelpApp(
    model: BighelpAppModel,
    versionName: String,
    onOpenPrivacyPolicy: () -> Unit,
) {
    val state by model.state.collectAsStateWithLifecycle()
    val dark = when (state.appearance) {
        Appearance.Automatic -> isSystemInDarkTheme()
        Appearance.Light -> false
        Appearance.Dark -> true
    }
    BighelpTheme(darkTheme = dark) {
        // Test tags double as resource IDs so UI Automator and adb-driven checks can find real controls.
        Surface(
            color = MaterialTheme.colorScheme.background,
            modifier = Modifier.fillMaxSize().semantics { testTagsAsResourceId = true },
        ) {
            BackHandler(enabled = state.backStack.size > 1) { model.back() }
            val demo = state.demo
            when (val route = state.route) {
                Route.Welcome -> WelcomeScreen(onTryDemo = model::tryDemo, onConnect = model::connectComputer)
                Route.Consent -> ConsentScreen(
                    onAgree = model::agreeToAiData,
                    onNotNow = { model.back() },
                    onPrivacyPolicy = onOpenPrivacyPolicy,
                )
                Route.Setup -> SetupScreen(
                    setup = state.setup,
                    onBack = { model.back() },
                    onAddress = model::setAddress,
                    onAllowPrivateHttp = model::setAllowPrivateHttp,
                    onCheck = model::checkHost,
                    onCancel = model::cancelCheck,
                    onTryDemo = model::tryDemo,
                )
                // The demo places exist only while the demo does.
                Route.Sessions -> demo?.let {
                    SessionsScreen(it, model::setSearch, model::openChat, model::startNewChat, model::openPlace)
                }
                Route.Agents -> demo?.let { AgentsScreen(it, model::selectAgent, model::startNewChat, model::openPlace) }
                Route.Settings -> SettingsScreen(
                    appearance = state.appearance,
                    consentGranted = state.consentGranted,
                    versionName = versionName,
                    onAppearance = model::setAppearance,
                    onPrivacyPolicy = onOpenPrivacyPolicy,
                    onLeaveDemo = model::leaveDemo,
                    onOpenPlace = model::openPlace,
                )
                is Route.Chat -> demo?.let {
                    ChatScreen(
                        demo = it,
                        sessionId = route.sessionId,
                        onBack = { model.back() },
                        onDraft = { text -> model.setDraft(route.sessionId, text) },
                        onSend = { model.send(route.sessionId) },
                    )
                }
            }
        }
    }
}
