package app.bighelp.android

import app.bighelp.android.live.ComputerPhase
import app.bighelp.android.live.LiveRig
import app.bighelp.hermes.AuthProvider
import app.bighelp.hermes.AuthStatus
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.SignInInput
import app.bighelp.hermes.chat.ConversationRef
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

private class Prefs(
    override var aiDataAgreed: Boolean = true,
    override var appearance: Appearance = Appearance.Automatic,
    override var userName: String = "",
    override var nerdMode: Boolean = false,
) : PreviewPreferences

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class LiveNavigationTest {
    @get:Rule val temporary = TemporaryFolder()
    private val noCheck = HostChecker { _, _ -> DiscoveryResult.Unavailable }
    private val ref = ConversationRef("default", "anchor-1")

    private fun TestScope.setup(preferences: Prefs = Prefs()): Pair<LiveRig, BighelpAppModel> {
        val rig = LiveRig(temporary.root, backgroundScope)
        return rig to BighelpAppModel(preferences, noCheck, backgroundScope, rig.model)
    }

    @Test fun aConnectedComputerOpensTheLivePlacesAndLosingItGoesBackToWelcome() = runTest {
        val (rig, model) = setup()
        runCurrent()
        assertEquals(Route.Welcome, model.state.value.route)
        assertFalse(model.state.value.live)
        rig.connect(); runCurrent()
        assertTrue(model.state.value.live)
        assertEquals(listOf<Route>(Route.Sessions), model.state.value.backStack)
        assertNull("The demo is gone once a real computer is open", model.state.value.demo)
        rig.model.disconnect().join(); runCurrent()
        assertFalse(model.state.value.live)
        assertEquals(listOf<Route>(Route.Welcome), model.state.value.backStack)
    }

    @Test fun replacingTheActiveComputerDoesNotBounceThroughWelcome() = runTest {
        val (rig, model) = setup()
        rig.connect(); runCurrent()
        val routes = mutableListOf<List<Route>>()
        val watcher = backgroundScope.launchCollect(model) { routes += it }
        runCurrent()
        rig.model.select(rig.connections.state.value.selectedID!!).join(); runCurrent()
        assertTrue(model.state.value.live)
        assertTrue("Never showed Welcome while switching: $routes", routes.none { it == listOf<Route>(Route.Welcome) })
        watcher.cancel()
    }

    @Test fun theLivePlacesAndMenuWorkOnlyWhileARealComputerIsOpen() = runTest {
        val (rig, model) = setup()
        model.openPlace(Route.Agents)
        assertEquals("No place opens without a computer or the demo", Route.Welcome, model.state.value.route)
        rig.connect(); runCurrent()
        model.openPlace(Route.Agents)
        assertEquals(listOf<Route>(Route.Sessions, Route.Agents), model.state.value.backStack)
        model.openPlace(Route.Sessions)
        assertEquals(listOf<Route>(Route.Sessions), model.state.value.backStack)
    }

    @Test fun theLiveHostCheckSendsTheAccessDetailsAndShowsTheHostsOptions() = runTest {
        val (rig, model) = setup()
        rig.prepare = { it.status = AuthStatus(true, listOf("native_pkce"), listOf(AuthProvider("basic", "Password", true))) }
        model.connectComputer(); runCurrent()
        model.setAddress("hermes.example.test")
        model.setAccess(AccessInput(AccessKind.ProxyLogin, "gate-user", "gate-pass"))
        model.checkHost(); runCurrent()
        val found = model.state.value.setup.discovery as DiscoveryState.Found
        assertTrue(found.authRequired)
        assertTrue(found.browserSignIn)
        assertEquals(ComputerPhase.SignIn, rig.connections.state.value.phase)
        model.continueToSignIn()
        assertEquals(Route.SignIn, model.state.value.route)
    }

    @Test fun anInvalidAccessFormIsExplainedBeforeAnyRequestIsMade() = runTest {
        val (rig, model) = setup()
        model.connectComputer(); runCurrent()
        model.setAddress("hermes.example.test")
        model.setAccess(AccessInput(AccessKind.Cloudflare, "has space", "secret"))
        model.checkHost(); runCurrent()
        val refused = model.state.value.setup.discovery as DiscoveryState.Refused
        assertTrue(refused.message.contains("access", ignoreCase = true))
        assertTrue("Nothing was built or sent", rig.sessions.isEmpty())
    }

    @Test fun aRefusedLiveCheckShowsTheHostsReasonInPlainWords() = runTest {
        val (rig, model) = setup()
        rig.prepare = { it.discoverFailure = HermesException.Kind.WebPageInsteadOfHermes }
        model.connectComputer(); runCurrent()
        model.setAddress("hermes.example.test")
        model.checkHost(); runCurrent()
        val refused = model.state.value.setup.discovery as DiscoveryState.Refused
        assertTrue(refused.message.contains("web page"))
    }

    @Test fun aRefusedCheckWhileAddingAComputerKeepsThePersonOnSetupAndBackReopensTheOpenOne() = runTest {
        val (rig, model) = setup()
        rig.connect(); runCurrent()
        val first = rig.connections.state.value.selectedID!!
        model.openPlace(Route.Settings)
        model.connectComputer(); runCurrent()
        assertEquals(Route.Setup, model.state.value.route)
        rig.prepare = { it.discoverFailure = HermesException.Kind.ConnectionFailed }
        model.setAddress("second.example.test")
        model.checkHost(); runCurrent()
        assertTrue(model.state.value.setup.discovery is DiscoveryState.Refused)
        assertEquals("Not thrown out to Welcome by the failed check", Route.Setup, model.state.value.route)
        assertTrue(model.state.value.live)

        model.back(); runCurrent()
        assertEquals(Route.Settings, model.state.value.route)
        assertEquals("The computer that was open is open again", first, rig.connections.active.value?.computer?.id)
        assertTrue(model.state.value.live)
    }

    @Test fun typedAccessSecretsAreForgottenWhenTheSetupScreenIsLeft() = runTest {
        val (_, model) = setup()
        model.connectComputer(); runCurrent()
        model.setAddress("hermes.example.test")
        model.setAccess(AccessInput(AccessKind.ProxyLogin, "gate-user", "gate-pass", listOf("X-Access-Id" to "synthetic")))
        model.back(); runCurrent()
        assertEquals(AccessInput(), model.state.value.setup.access)
        assertEquals("The address the person typed stays", "hermes.example.test", model.state.value.setup.address)
    }

    @Test fun leavingTheSignInCancelsItAndGoesBack() = runTest {
        val (rig, model) = setup()
        model.connectComputer(); runCurrent()
        model.setAddress("hermes.example.test")
        model.checkHost(); runCurrent()
        model.continueToSignIn()
        model.back()
        runCurrent()
        assertEquals(Route.Setup, model.state.value.route)
        assertEquals(ComputerPhase.Idle, rig.connections.state.value.phase)
    }

    @Test fun signingInToAnAddedComputerEndsOnTheChatList() = runTest {
        val (rig, model) = setup()
        model.connectComputer(); runCurrent()
        model.setAddress("hermes.example.test")
        model.checkHost(); runCurrent()
        model.continueToSignIn()
        model.signIn("Garden computer", SignInInput.Dashboard)
        runCurrent()
        assertEquals(listOf<Route>(Route.Sessions), model.state.value.backStack)
        assertTrue(model.state.value.live)
    }

    @Test fun openingAndLeavingALiveChatOpensThenReleasesIt() = runTest {
        val (rig, model) = setup()
        rig.connect(); runCurrent()
        rig.chat.conversations.value = mapOf(ref to rig.chat.state(ref))
        runCurrent()
        model.openLiveChat(ref); runCurrent()
        assertEquals(Route.LiveChat(ref.id), model.state.value.route)
        assertEquals(listOf(ref), rig.chat.opened)
        model.back(); runCurrent()
        assertEquals(Route.Sessions, model.state.value.route)
        assertEquals(listOf(ref), rig.chat.released)
    }

    @Test fun aChatLinkThatIsNotOneWeMadeOpensNothing() = runTest {
        val (rig, model) = setup()
        rig.connect(); runCurrent()
        model.openLiveChat(null)
        assertEquals(Route.Sessions, model.state.value.route)
        assertTrue(rig.chat.opened.isEmpty())
    }

    @Test fun theNameIsShortAndSingleLineAndNerdModeIsRemembered() = runTest {
        val preferences = Prefs()
        val (_, model) = setup(preferences)
        model.setUserName("  Ada\nLovelace  ")
        assertEquals("Ada Lovelace", model.state.value.userName)
        assertEquals("Ada Lovelace", preferences.userName)
        model.setUserName("x".repeat(60))
        assertEquals(40, model.state.value.userName.length)
        model.setNerdMode(true)
        assertTrue(preferences.nerdMode)
        assertTrue(model.state.value.nerdMode)
        val restored = BighelpAppModel(preferences, noCheck, backgroundScope)
        assertEquals(true, restored.state.value.nerdMode)
        assertEquals(40, restored.state.value.userName.length)
    }
}

private fun kotlinx.coroutines.CoroutineScope.launchCollect(model: BighelpAppModel, sink: (List<Route>) -> Unit) =
    launch { model.state.collect { sink(it.backStack) } }
