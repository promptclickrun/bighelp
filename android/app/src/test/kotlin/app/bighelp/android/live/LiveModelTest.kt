package app.bighelp.android.live

import app.bighelp.hermes.AuthProvider
import app.bighelp.hermes.AuthStatus
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.chat.ChatError
import app.bighelp.hermes.chat.ChatException
import app.bighelp.hermes.chat.ConversationRef
import app.bighelp.hermes.chat.SendMode
import app.bighelp.hermes.chat.SendResult
import app.bighelp.hermes.chat.Admission
import app.bighelp.hermes.chat.SessionSearchResult
import app.bighelp.hermes.chat.SessionSummary
import app.bighelp.hermes.chat.ArchiveState
import app.bighelp.hermes.chat.AgentSummary
import app.bighelp.hermes.chat.CatalogState
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class LiveModelTest {
    @get:Rule val temporary = TemporaryFolder()
    private val ref = ConversationRef("default", "anchor-1")
    private val other = ConversationRef("default", "anchor-2")

    private fun TestScopeRig(scope: kotlinx.coroutines.CoroutineScope, delays: List<Long> = listOf(2_000, 6_000, 18_000)) = LiveRig(temporary.root, scope, delays)

    // ---- coming back, and losing the connection

    @Test fun comingBackToTheFrontAsksTheActiveComputerToResume() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect()
        rig.model.onForeground()
        runCurrent()
        assertEquals(1, rig.session.resumed)
    }

    @Test fun comingBackDoesNotReconnectAComputerThePersonDisconnected() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect()
        rig.model.connections.disconnect().join()
        rig.model.onForeground(); runCurrent()
        assertEquals("No new session was made for a deliberate disconnect", 1, rig.sessions.size)
    }

    @Test fun aLostConnectionIsRetriedWithGrowingPausesWhileInFrontAndStopsOnceItIsBack() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect()
        rig.model.onForeground(); runCurrent()
        rig.session.reconnectFailures += listOf(ChatException(ChatError.Kind.HostUnavailable), ChatException(ChatError.Kind.HostUnavailable))
        rig.session.link.value = ComputerLink.Offline
        runCurrent()
        assertEquals(0, rig.session.reconnects)
        advanceTimeBy(2_001); runCurrent()
        assertEquals(1, rig.session.reconnects)
        advanceTimeBy(6_000); runCurrent()
        assertEquals(2, rig.session.reconnects)
        advanceTimeBy(18_000); runCurrent()
        assertEquals("The third attempt worked", 3, rig.session.reconnects)
        rig.session.link.value = ComputerLink.Connected
        runCurrent()
        advanceTimeBy(120_000); runCurrent()
        assertEquals("No more attempts once connected", 3, rig.session.reconnects)
        assertNull(rig.model.reconnectProblem.value)
    }

    @Test fun retriesStopAfterTheLastPauseAndLeaveTheManualReconnect() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); rig.model.onForeground(); runCurrent()
        rig.session.reconnectFailures += List(10) { ChatException(ChatError.Kind.HostUnavailable) }
        rig.session.link.value = ComputerLink.Offline
        runCurrent()
        advanceTimeBy(60_000); runCurrent()
        assertEquals(3, rig.session.reconnects)
        rig.model.reconnectNow(); runCurrent()
        assertEquals(4, rig.session.reconnects)
        assertNotNull("A failed manual reconnect says so", rig.model.notice.value)
    }

    @Test fun nothingIsRetriedWhileTheAppIsInTheBackground() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); rig.model.onForeground(); runCurrent()
        rig.session.link.value = ComputerLink.Offline
        runCurrent()
        advanceTimeBy(1_000); rig.model.onBackground(); runCurrent()
        advanceTimeBy(120_000); runCurrent()
        assertEquals(0, rig.session.reconnects)
        rig.model.onForeground(); runCurrent()
        advanceTimeBy(2_001); runCurrent()
        assertEquals("Back in front, the retries start again", 1, rig.session.reconnects)
    }

    @Test fun aRefusedSignInStopsTheRetriesAndAsksForANewSignIn() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); rig.model.onForeground(); runCurrent()
        rig.session.reconnectFailures += ChatException(ChatError.Kind.SignInRequired)
        rig.session.link.value = ComputerLink.Offline
        runCurrent()
        advanceTimeBy(2_001); runCurrent()
        advanceTimeBy(120_000); runCurrent()
        assertEquals(1, rig.session.reconnects)
        assertEquals(ChatError.Kind.SignInRequired, rig.model.reconnectProblem.value)
    }

    // ---- setup

    @Test fun discoveryHandsBackTheHostsSignInOptions() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.prepare = { it.status = AuthStatus(true, listOf("native_pkce"), listOf(AuthProvider("basic", "Password", true))) }
        val outcome = rig.model.beginSetup(rig.endpoint, AccessSetup.None)
        assertEquals(ComputerPhase.SignIn, rig.connections.state.value.phase)
        assertEquals("basic", (outcome as SetupOutcome.Ready).status.providers.single().name)
        rig.model.cancelSetup().join()
    }

    @Test fun aGateRefusalIsReportedInPlainWordsAndLeavesNothingBehind() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.prepare = { it.discoverFailure = HermesException.Kind.CloudflareAccessDenied }
        val outcome = rig.model.beginSetup(rig.endpoint, AccessSetup.None)
        assertTrue(outcome is SetupOutcome.Failed)
        assertTrue((outcome as SetupOutcome.Failed).message.contains("access", ignoreCase = true))
        assertNull(rig.connections.active.value)
    }

    @Test fun cancellingSetupWhileItRunsIsNotAFailure() = runTest {
        val rig = TestScopeRig(backgroundScope)
        val pending = kotlinx.coroutines.CompletableDeferred<SetupOutcome>()
        rig.prepare = { }
        val outcome = rig.model.beginSetup(rig.endpoint, AccessSetup.None)
        rig.model.cancelSetup().join()
        pending.complete(outcome)
        assertTrue("A finished setup that was then cancelled is Ready, and a later cancel changes the phase only", rig.connections.state.value.phase == ComputerPhase.Idle)
    }

    @Test fun aFailedSignInCanBeTriedAgainOnTheSameScreenWithoutStartingOver() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.prepare = { it.signInFailure = if (rig.sessions.size == 1) HermesException.Kind.InvalidCredentials else null }
        rig.model.beginSetup(rig.endpoint, AccessSetup.None)
        rig.model.signIn("Garden computer", app.bighelp.hermes.SignInInput.Token("synthetic-token-0123456789")).join()
        assertEquals(ComputerPhase.Failed, rig.connections.state.value.phase)
        assertEquals(HermesException.Kind.InvalidCredentials, rig.connections.state.value.authFailure)

        rig.model.signIn("Garden computer", app.bighelp.hermes.SignInInput.Token("synthetic-token-0123456789")).join()
        runCurrent()
        assertEquals("The second try ran on a fresh session", 2, rig.sessions.size)
        assertEquals(ComputerPhase.Connected, rig.connections.state.value.phase)
        assertEquals(1, rig.sessions.count { it.closed })
    }

    // ---- sending

    @Test fun anAdmittedSendClearsTheComposerAndARefusalKeepsTheText() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); runCurrent()
        rig.chat.nextSend = SendResult.Admitted("e1", Admission.Streaming)
        assertEquals(SendOutcome.Sent, rig.model.send(ref, "hello", SendMode.Default))
        assertEquals(Triple(ref, "hello", SendMode.Default), rig.chat.sends.single())

        rig.chat.nextSend = SendResult.NotSent(ChatError(ChatError.Kind.PersistenceFailed))
        val kept = rig.model.send(ref, "again", SendMode.Default)
        assertTrue(kept is SendOutcome.Kept)
        assertTrue((kept as SendOutcome.Kept).message.contains("nothing was sent"))
    }

    @Test fun aSendWhoseOutcomeIsUnknownLeavesTheComposerClearButTellsThePersonToReview() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); runCurrent()
        rig.chat.nextSend = SendResult.Uncertain("e1", ChatError(ChatError.Kind.OutcomeUnknown))
        assertEquals(SendOutcome.Sent, rig.model.send(ref, "maybe", SendMode.Default))
        assertTrue(rig.model.notice.value!!.text.contains("couldn't"))
    }

    @Test fun aTypedCommandIsCheckedAgainstTheHostsCommandListBeforeItIsSent() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); runCurrent()
        rig.chat.commandIndex = app.bighelp.hermes.chat.SlashCommandIndex(listOf(
            app.bighelp.hermes.chat.SlashCommand("plan", "Plan first", "Commands", emptyList(), app.bighelp.hermes.chat.ArgumentMode.Text, app.bighelp.hermes.chat.CommandSource.Core),
        ))
        rig.chat.nextSend = SendResult.Admitted("e1", Admission.CommandOutput)
        rig.model.send(ref, "/plan the trip", SendMode.Default)
        assertEquals("plan", rig.chat.sendSelections.single()!!.command.name)
        rig.model.send(ref, "/unknown thing", SendMode.Default)
        assertNull("A command the host does not list is sent as the host decides, not as a guess", rig.chat.sendSelections.last())
        rig.model.send(ref, "plain words", SendMode.Default)
        assertEquals("Ordinary text never asks for the command list", 1, rig.chat.commandCalls)
    }

    // ---- drafts

    @Test fun typingSavesOneDraftAfterThePauseAndASendCancelsAPendingSave() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); runCurrent()
        rig.model.editDraft(ref, "h"); advanceTimeBy(100)
        rig.model.editDraft(ref, "he"); advanceTimeBy(100)
        rig.model.editDraft(ref, "hel"); advanceTimeBy(200); runCurrent()
        assertEquals("Not yet: the pause restarted with every key", emptyList<Any>(), rig.chat.drafts)
        advanceTimeBy(150); runCurrent()
        assertEquals(listOf(ref to "hel"), rig.chat.drafts)

        rig.chat.nextSend = SendResult.Admitted("e", Admission.Streaming)
        rig.model.editDraft(ref, "sent text")
        rig.model.send(ref, "sent text", SendMode.Default)
        advanceTimeBy(5_000); runCurrent()
        assertEquals("A send's own clearing wins over a save that was still waiting", listOf(ref to "hel"), rig.chat.drafts)
    }

    @Test fun leavingAChatSavesItsDraftAtOnce() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); runCurrent()
        rig.model.editDraft(ref, "unfinished")
        rig.model.leaveChat(ref)
        assertEquals(listOf(ref to "unfinished"), rig.chat.drafts)
        advanceTimeBy(5_000); runCurrent()
        assertEquals("The waiting save did not run a second time", 1, rig.chat.drafts.size)
    }

    // ---- what stays retained

    @Test fun leavingAChatReleasesItOnlyWhenNothingIsRunningOrWaitingForTheReader() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); runCurrent()
        rig.chat.conversations.value = mapOf(ref to rig.chat.state(ref), other to rig.chat.state(other, running = true))
        rig.model.leaveChat(ref)
        rig.model.leaveChat(other)
        assertEquals(listOf(ref), rig.chat.released)
    }

    @Test fun openingAChatReleasesOtherIdleOnesButNotARunningOne() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); runCurrent()
        val third = ConversationRef("default", "anchor-3")
        rig.chat.conversations.value = mapOf(other to rig.chat.state(other), third to rig.chat.state(third, running = true))
        rig.model.openChat(ref)
        assertEquals(listOf(ref), rig.chat.opened)
        assertEquals(listOf(other), rig.chat.released)
    }

    // ---- search

    private fun summary(profile: String, anchor: String, title: String) = SessionSummary(
        ConversationRef(profile, anchor), profile, anchor, title, "", null, 1.0, 1, "bighelp", null, false, ArchiveState.None, null, null, false, false,
    )

    @Test fun contentSearchWaitsForAPauseThenAsksEachAgentOnceAndKeepsOnlyTheLatestQuery() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); runCurrent()
        rig.chat.catalog.value = CatalogState(agents = listOf("default", "moss").map { AgentSummary(it, it, null, JsonObject(emptyMap())) })
        rig.chat.searchResults = { profile, query -> listOf(SessionSearchResult(summary(profile, "hit-$profile", "Hit in $profile"), "…$query…")) }
        runCurrent()
        rig.model.setSearch("ro"); advanceTimeBy(200)
        rig.model.setSearch("rou"); advanceTimeBy(300); runCurrent()
        assertTrue("Still waiting: the pause restarted", rig.chat.searches.isEmpty())
        advanceTimeBy(200); runCurrent()
        assertEquals(setOf("default" to "rou", "moss" to "rou"), rig.chat.searches.toSet())
        assertEquals(setOf("Hit in default", "Hit in moss"), rig.model.contentHits.value.map { it.title }.toSet())
        rig.model.setSearch("")
        runCurrent()
        assertTrue(rig.model.contentHits.value.isEmpty())
    }

    @Test fun aOneLetterQueryAsksTheHostNothing() = runTest {
        val rig = TestScopeRig(backgroundScope)
        rig.connect(); runCurrent()
        rig.chat.catalog.value = CatalogState(agents = listOf(AgentSummary("default", "default", null, JsonObject(emptyMap()))))
        runCurrent()
        rig.model.setSearch("r"); advanceTimeBy(5_000); runCurrent()
        assertTrue(rig.chat.searches.isEmpty())
    }
}
