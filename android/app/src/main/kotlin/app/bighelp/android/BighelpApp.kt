package app.bighelp.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.bighelp.android.live.LiveModel

/**
 * The whole app: observes [BighelpAppModel] and shows its current route. Screens only call the model's
 * actions; they hold no navigation or demo state of their own except scroll position and the message box.
 * The same places show the demo's sample data or, when a real computer is open, its own agents and chats.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun BighelpApp(
    model: BighelpAppModel,
    versionName: String,
    onOpenPrivacyPolicy: () -> Unit,
) {
    val state by model.state.collectAsStateWithLifecycle()
    val live = model.live
    val dark = when (state.appearance) {
        Appearance.Automatic -> isSystemInDarkTheme()
        Appearance.Light -> false
        Appearance.Dark -> true
    }
    // The connection is only kept up, and retried, while the app is in front.
    LifecycleEventEffect(Lifecycle.Event.ON_START) { live?.onForeground() }
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { live?.onBackground() }
    BighelpTheme(darkTheme = dark) {
        // Test tags double as resource IDs so UI Automator and adb-driven checks can find real controls.
        Surface(
            color = MaterialTheme.colorScheme.background,
            modifier = Modifier.fillMaxSize().semantics { testTagsAsResourceId = true },
        ) {
            BackHandler(enabled = state.backStack.size > 1) { model.back() }
            Box(Modifier.fillMaxSize()) {
                Screens(model, live, state, versionName, onOpenPrivacyPolicy)
                if (live != null) NoticeHost(live, Modifier.align(Alignment.BottomCenter).safeDrawingPadding().padding(bottom = 72.dp))
            }
        }
    }
}

@Composable
private fun Screens(model: BighelpAppModel, live: LiveModel<*>?, state: AppState, versionName: String, onOpenPrivacyPolicy: () -> Unit) {
    val demo = state.demo
    when (val route = state.route) {
        Route.Welcome -> WelcomeScreen(
            onTryDemo = model::tryDemo,
            onConnect = model::connectComputer,
            extra = { if (live != null) WelcomeComputers(model, live) },
        )
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
            live = live != null,
            onAccess = model::setAccess,
            onContinue = model::continueToSignIn,
        )
        Route.SignIn -> if (live != null) {
            val connection by live.connections.state.collectAsStateWithLifecycle()
            SignInScreen(
                connection = connection,
                defaultName = state.signInName.ifBlank { "My computer" },
                onSignIn = model::signIn,
                onBack = { model.back() },
            )
        }
        // The places exist only while the demo or a real computer is open.
        Route.Sessions -> when {
            demo != null -> SessionsScreen(demo, model::setSearch, model::openChat, model::startNewChat, model::openPlace)
            state.live && live != null -> LiveSessionsScreen(
                live,
                onOpenChat = model::openLiveChat,
                onNewChat = { model.startLiveChat() },
                onOpenArchived = { model.openArchived() },
                onOpenPlace = model::openPlace,
                onSignInAgain = model::signInAgainSelected,
            )
        }
        Route.Agents -> when {
            demo != null -> AgentsScreen(demo, model::selectAgent, model::startNewChat, model::openPlace)
            state.live && live != null -> LiveAgentsScreen(
                live,
                onNewChat = { model.startLiveChat(it) },
                onBotChat = model::openBotChat,
                onOpenPlace = model::openPlace,
                onSignInAgain = model::signInAgainSelected,
            )
        }
        Route.Archived -> if (live != null) ArchivedChatsScreen(live, onBack = { model.back() })
        Route.Settings -> SettingsScreen(
            appearance = state.appearance,
            consentGranted = state.consentGranted,
            versionName = versionName,
            onAppearance = model::setAppearance,
            onPrivacyPolicy = onOpenPrivacyPolicy,
            onLeaveDemo = model::leaveDemo,
            onOpenPlace = model::openPlace,
            showDemo = demo != null,
            liveSections = if (state.live && live != null) ({ LiveSettingsSections(model, live, state) }) else null,
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
        is Route.LiveChat -> if (live != null) LiveChatScreen(
            live,
            refId = route.refId,
            onBack = { model.back() },
            onOpenChat = model::openLiveChat,
            onSignInAgain = model::signInAgainSelected,
        )
    }
}

@Composable
private fun WelcomeComputers(model: BighelpAppModel, live: LiveModel<*>) {
    val connection by live.connections.state.collectAsStateWithLifecycle()
    if (connection.computers.isEmpty()) return
    androidx.compose.foundation.layout.Column {
        SectionLabel("Your computers")
        androidx.compose.foundation.layout.Spacer(Modifier.padding(top = 4.dp))
        SavedComputersCard(live, onSignInAgain = model::signInAgain)
        androidx.compose.foundation.layout.Spacer(Modifier.padding(top = 20.dp))
    }
}
