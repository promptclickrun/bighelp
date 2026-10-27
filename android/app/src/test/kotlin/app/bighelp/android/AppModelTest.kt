package app.bighelp.android

import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.HermesEndpointException.Reason
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class FakePreferences(
    override var aiDataAgreed: Boolean = false,
    override var appearance: Appearance = Appearance.Automatic,
) : PreviewPreferences

/** Records every request it is asked to make; [answer] decides when and how each one finishes. */
private class RecordingChecker(
    var answer: suspend () -> DiscoveryResult = { DiscoveryResult.Unavailable },
) : HostChecker {
    val calls = mutableListOf<Pair<String, Boolean>>()
    var cancelled = 0

    override suspend fun check(endpoint: HermesEndpoint, consentGranted: Boolean): DiscoveryResult {
        calls += endpoint.canonical to consentGranted
        try {
            return answer()
        } catch (e: CancellationException) {
            cancelled++
            throw e
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class AppModelTest {
    private fun TestScope.model(
        preferences: FakePreferences = FakePreferences(),
        checker: RecordingChecker = RecordingChecker(),
    ) = BighelpAppModel(preferences, checker, backgroundScope)

    private fun BighelpAppModel.demo() = state.value.demo!!

    // -- consent and the host check ------------------------------------------------------------

    @Test fun connectingAsksForTheAgreementFirstAndNothingIsCheckedUntilItIsGiven() = runTest {
        val preferences = FakePreferences()
        val checker = RecordingChecker()
        val model = model(preferences, checker)

        model.connectComputer()
        assertEquals(Route.Consent, model.state.value.route)

        model.setAddress("hermes.example")
        model.checkHost()
        runCurrent()
        assertTrue(checker.calls.isEmpty())
        assertEquals(Route.Consent, model.state.value.route)

        model.agreeToAiData()
        assertTrue(preferences.aiDataAgreed)
        // Consent is replaced by setup, so Back from setup does not show the agreement again.
        assertEquals(listOf(Route.Welcome, Route.Setup), model.state.value.backStack)

        model.checkHost()
        runCurrent()
        assertEquals(listOf("https://hermes.example" to true), checker.calls)
    }

    @Test fun anEarlierAgreementGoesStraightToSetup() = runTest {
        val model = model(FakePreferences(aiDataAgreed = true))
        model.connectComputer()
        assertEquals(Route.Setup, model.state.value.route)
        assertTrue(model.state.value.consentGranted)
    }

    @Test fun anInvalidAddressNeverReachesTheNetworkAndNeverEchoesTheInput() = runTest {
        val checker = RecordingChecker()
        val model = model(FakePreferences(aiDataAgreed = true), checker)
        model.connectComputer()

        model.setAddress("http://hermes.example")
        model.checkHost()
        assertEquals(DiscoveryState.AddressProblem(Reason.PlaintextNotAllowed), model.state.value.setup.discovery)

        model.setAddress("user:secret@hermes.example")
        model.checkHost()
        assertEquals(DiscoveryState.AddressProblem(Reason.InvalidEndpoint), model.state.value.setup.discovery)

        runCurrent()
        assertTrue(checker.calls.isEmpty())
    }

    @Test fun privateHttpNeedsTheExplicitSwitchAndAPrivateAddress() = runTest {
        val checker = RecordingChecker()
        val model = model(FakePreferences(aiDataAgreed = true), checker)
        model.connectComputer()

        model.setAddress("http://192.168.1.20:9119")
        model.checkHost()
        assertEquals(DiscoveryState.AddressProblem(Reason.PlaintextNotAllowed), model.state.value.setup.discovery)

        model.setAllowPrivateHttp(true)
        assertEquals(DiscoveryState.Idle, model.state.value.setup.discovery)
        model.checkHost()
        runCurrent()
        assertEquals(listOf("http://192.168.1.20:9119" to true), checker.calls)

        // A public address stays refused even with the switch on.
        model.setAddress("http://hermes.example.com")
        model.checkHost()
        assertEquals(DiscoveryState.AddressProblem(Reason.PlaintextNotAllowed), model.state.value.setup.discovery)
    }

    @Test fun aFoundComputerIsNotAConnection() = runTest {
        val checker = RecordingChecker { DiscoveryResult.Available(authRequired = true, browserSignIn = true) }
        val model = model(FakePreferences(aiDataAgreed = true), checker)
        model.connectComputer()
        model.setAddress(" hermes.example/hermes \n")
        model.checkHost()
        runCurrent()

        assertEquals(
            DiscoveryState.Found("https://hermes.example/hermes", authRequired = true, browserSignIn = true),
            model.state.value.setup.discovery,
        )
        // Still on setup; no demo, no chat, nothing opened.
        assertEquals(Route.Setup, model.state.value.route)
        assertNull(model.state.value.demo)
    }

    @Test fun anUnreachableComputerIsReportedWithoutDetail() = runTest {
        val checker = RecordingChecker { DiscoveryResult.Unavailable }
        val model = model(FakePreferences(aiDataAgreed = true), checker)
        model.connectComputer()
        model.setAddress("hermes.example")
        model.checkHost()
        runCurrent()
        assertEquals(DiscoveryState.Unavailable("https://hermes.example"), model.state.value.setup.discovery)
    }

    @Test fun onlyOneCheckRunsAtATime() = runTest {
        val gate = CompletableDeferred<DiscoveryResult>()
        val checker = RecordingChecker { gate.await() }
        val model = model(FakePreferences(aiDataAgreed = true), checker)
        model.connectComputer()
        model.setAddress("hermes.example")

        model.checkHost()
        model.checkHost()
        runCurrent()
        assertEquals(1, checker.calls.size)
        assertEquals(DiscoveryState.Checking, model.state.value.setup.discovery)

        gate.complete(DiscoveryResult.Available(authRequired = false, browserSignIn = false))
        runCurrent()
        assertTrue(model.state.value.setup.discovery is DiscoveryState.Found)
    }

    @Test fun changingTheInputDropsTheOldResultAndCancelsTheCheck() = runTest {
        val checker = RecordingChecker { CompletableDeferred<DiscoveryResult>().await() }
        val model = model(FakePreferences(aiDataAgreed = true), checker)
        model.connectComputer()
        model.setAddress("old.example")
        model.checkHost()
        runCurrent()

        model.setAddress("new.example")
        assertEquals(DiscoveryState.Idle, model.state.value.setup.discovery)
        runCurrent()
        assertEquals(1, checker.cancelled)
        assertEquals("new.example", model.state.value.setup.address)
    }

    @Test fun anAnswerThatArrivesAfterTheInputChangedIsNeverApplied() = runTest {
        // A checker that swallows cancellation and still answers: only the model's own fence stops it.
        val checker = RecordingChecker {
            try {
                CompletableDeferred<DiscoveryResult>().await()
            } catch (_: CancellationException) {
                DiscoveryResult.Available(authRequired = false, browserSignIn = false)
            }
        }
        val model = model(FakePreferences(aiDataAgreed = true), checker)
        model.connectComputer()
        model.setAddress("old.example")
        model.checkHost()
        runCurrent()

        model.setAddress("new.example")
        runCurrent()
        assertEquals(DiscoveryState.Idle, model.state.value.setup.discovery)

        // The new input can be checked normally afterwards.
        checker.answer = { DiscoveryResult.Unavailable }
        model.checkHost()
        runCurrent()
        assertEquals(DiscoveryState.Unavailable("https://new.example"), model.state.value.setup.discovery)
    }

    @Test fun leavingSetupCancelsTheCheckInFlight() = runTest {
        val checker = RecordingChecker { CompletableDeferred<DiscoveryResult>().await() }
        val model = model(FakePreferences(aiDataAgreed = true), checker)
        model.connectComputer()
        model.setAddress("hermes.example")
        model.checkHost()
        runCurrent()

        assertTrue(model.back())
        runCurrent()
        assertEquals(1, checker.cancelled)
        assertEquals(DiscoveryState.Idle, model.state.value.setup.discovery)
        assertEquals(Route.Welcome, model.state.value.route)
    }

    // -- demo ---------------------------------------------------------------------------------

    @Test fun theDemoIsSampleDataThatNeedsNeitherAgreementNorTheNetwork() = runTest {
        val preferences = FakePreferences()
        val checker = RecordingChecker()
        val model = model(preferences, checker)

        model.tryDemo()
        runCurrent()

        assertEquals(Route.Sessions, model.state.value.route)
        assertFalse(preferences.aiDataAgreed)
        assertTrue(checker.calls.isEmpty())
        assertTrue(model.demo().sessions.isNotEmpty())
        assertTrue(model.demo().agents.size >= 2)
    }

    @Test fun sendingInTheDemoAddsYourMessageAndOneFixedExampleReply() = runTest {
        val model = model()
        model.tryDemo()
        model.startNewChat()
        val id = (model.state.value.route as Route.Chat).sessionId

        model.setDraft(id, "  What should I pack?  ")
        assertTrue(model.send(id))
        val session = model.demo().session(id)!!
        assertEquals(2, session.messages.size)
        assertEquals("What should I pack?", session.messages[0].text)
        assertTrue(session.messages[0].fromUser)
        assertFalse(session.messages[0].isExample)
        assertFalse(session.messages[1].fromUser)
        assertTrue(session.messages[1].isExample)
        assertEquals("What should I pack?", session.title)
        assertNull(model.demo().drafts[id])
        assertEquals(id, model.demo().sessions.first().id)

        // The reply is fixed text, the same every time, and says it is an example.
        model.setDraft(id, "Anything else?")
        model.send(id)
        val replies = model.demo().session(id)!!.messages.filter { it.isExample }
        assertEquals(2, replies.size)
        assertEquals(replies[0].text, replies[1].text)
        assertTrue(replies[0].text.contains("example", ignoreCase = true))
        assertEquals(4, model.demo().session(id)!!.messages.map { it.id }.toSet().size)
    }

    @Test fun aLongFirstMessageTitleNeverCutsAnEmojiInHalf() = runTest {
        val model = model()
        model.tryDemo()
        model.startNewChat()
        val id = (model.state.value.route as Route.Chat).sessionId

        // The 40-character title limit falls between the two halves of the emoji (a surrogate pair).
        val message = "a".repeat(39) + "😀 and some more words"
        model.setDraft(id, message)
        assertTrue(model.send(id))

        val session = model.demo().session(id)!!
        assertEquals("a".repeat(39) + "…", session.title)
        assertEquals(message, session.messages[0].text)
    }

    @Test fun aBlankDraftDoesNotSend() = runTest {
        val model = model()
        model.tryDemo()
        model.startNewChat()
        val id = (model.state.value.route as Route.Chat).sessionId
        model.setDraft(id, "   \n ")
        assertFalse(model.send(id))
        assertTrue(model.demo().session(id)!!.messages.isEmpty())
    }

    @Test fun aDraftSurvivesLeavingAndReturningToAChat() = runTest {
        val model = model()
        model.tryDemo()
        val first = model.demo().sessions.first().id
        model.openChat(first)
        model.setDraft(first, "Remember the sunscreen")

        assertTrue(model.back())
        assertEquals(Route.Sessions, model.state.value.route)
        assertEquals("Remember the sunscreen", model.demo().drafts[first])

        model.openChat(first)
        assertEquals("Remember the sunscreen", model.demo().drafts[first])

        // Clearing the box clears the stored draft, not just the visible one.
        model.setDraft(first, "")
        assertNull(model.demo().drafts[first])
    }

    @Test fun newChatReusesAnEmptyChatAndStartsWithTheSelectedAgent() = runTest {
        val model = model()
        model.tryDemo()
        val agent = model.demo().agents.last()
        model.selectAgent(agent.id)

        model.startNewChat()
        val first = (model.state.value.route as Route.Chat).sessionId
        assertEquals(agent.id, model.demo().session(first)!!.agentId)
        assertEquals(listOf(Route.Sessions, Route.Chat(first)), model.state.value.backStack)

        model.back()
        val before = model.demo().sessions.size
        model.startNewChat()
        assertEquals(Route.Chat(first), model.state.value.route)
        assertEquals(before, model.demo().sessions.size)
    }

    @Test fun searchMatchesTitlesAgentsAndMessages() = runTest {
        val model = model()
        model.tryDemo()
        val all = model.demo().sessions
        assertEquals(all, model.demo().visibleSessions)

        model.setSearch("ROUTER")
        assertEquals(listOf("router"), model.demo().visibleSessions.map { it.id })

        model.setSearch(model.demo().agent(all.first().agentId).name)
        assertTrue(model.demo().visibleSessions.any { it.id == all.first().id })

        model.setSearch("no chat says this zzzz")
        assertTrue(model.demo().visibleSessions.isEmpty())
    }

    @Test fun backWalksTheStackAndStopsAtTheRoot() = runTest {
        val model = model()
        model.tryDemo()
        model.openPlace(Route.Settings)
        assertEquals(listOf(Route.Sessions, Route.Settings), model.state.value.backStack)
        assertTrue(model.back())
        assertEquals(Route.Sessions, model.state.value.route)
        // The root is left to the system: Back there leaves the app.
        assertFalse(model.back())
    }

    @Test fun leavingTheDemoDropsItsChatsAndDrafts() = runTest {
        val model = model()
        model.tryDemo()
        val id = model.demo().sessions.first().id
        model.setDraft(id, "unsent")
        model.leaveDemo()
        assertNull(model.state.value.demo)
        assertEquals(listOf(Route.Welcome), model.state.value.backStack)

        model.tryDemo()
        assertNull(model.demo().drafts[id])
    }

    @Test fun appearanceIsSaved() = runTest {
        val preferences = FakePreferences()
        val model = model(preferences)
        model.setAppearance(Appearance.Dark)
        assertEquals(Appearance.Dark, preferences.appearance)
        assertEquals(Appearance.Dark, model.state.value.appearance)
    }
}
