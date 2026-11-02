package app.bighelp.hermes.chat

import app.bighelp.hermes.HermesException
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CommandRouterTest : ChatTestBase() {
    private suspend fun ChatRig.journal(ref: ConversationRef) =
        store.keys(ChatTestData.host, RecordKind.Journal, ref.profile, ref.anchor).map { JournalEntry.decode(scopeOf(ref), it.entry!!, store.read(it)!!) }

    private fun ChatRig.messages(ref: ConversationRef) = state(ref).items.filterIsInstance<MessageItem>()

    @Test fun theCatalogKeepsInvocationIdentityAliasesAndSourcesAndSkipsOnlyWhatItCannotShow() {
        val commands = SlashCommandCatalog.decode(jsonObject("""{
            "pairs":[["/help","Show\nhelp"],["/deploy-skill","Deploys"],["/model","Pick"],["/bad name","x"],["nothing","x"],["/é.x_y","Unicode ok"],["/${"a".repeat(97)}","too long"]],
            "canon":{"/h":"/help","/H2":"/help"},"skills":{"deploy-skill":{}},
            "categories":[{"name":"Plugin Commands","pairs":[["/model","Pick"]]}],
            "commands":{"/help":{"argument_mode":"options"}}}""").let { it })
        assertEquals(listOf("help", "deploy-skill", "model", "é.x_y"), commands.map { it.name })
        val help = commands[0]
        assertEquals("Show help", help.description)
        assertEquals(listOf("H2", "h"), help.aliases)
        assertEquals(ArgumentMode.Options, help.argumentMode)
        assertEquals(CommandSource.Core, help.source)
        assertEquals(CommandSource.Skill, commands[1].source)
        assertEquals(CommandSource.Plugin, commands[2].source)
        val index = SlashCommandIndex(commands)
        assertEquals("help", index.selection("/H now")!!.command.name)
        assertEquals("now", index.selection("/h now")!!.arguments)
        assertNull(index.selection("/unknown"))
        assertEquals(listOf("help"), index.suggestions("/he").map { it.name })
        assertEquals("Once it names a command there are no suggestions", emptyList<SlashCommand>(), index.suggestions("/help"))
    }

    @Test fun aCoreCommandRunsThroughSlashExecAndItsOutputIsOneResultWithNoTurn() = run {
        val r = rig()
        val ref = r.newChat()
        val result = r.repo.send(ref, "/help me")
        assertEquals(Admission.CommandOutput, (result as SendResult.Admitted).admission)
        val call = r.host.calls("slash.exec").single().params
        assertEquals("/help me", call["command"].asString)
        assertFalse("A command carries no queued flag", call.containsKey("queued"))
        assertEquals(0, r.host.count("prompt.submit"))
        r.eventually(message = "entry retired") { r.state(ref).unresolved.isEmpty() }
        val outputs = r.messages(ref).filter { it.isCommandResult }
        assertEquals(listOf("ran help"), outputs.map { it.text })
        assertNull(r.state(ref).sendBlock)
    }

    @Test fun aChosenSkillGoesThroughCommandDispatchAndItsExpansionIsSubmittedOnceWithTheExactBytes() = run {
        val r = rig()
        val ref = r.newChat()
        val index = r.repo.commands(ref)
        val selection = index.selection("/deploy-skill prod")!!
        assertEquals(CommandSource.Skill, selection.command.source)
        var journalMethodAtSubmit: String? = null
        var journalTextAtSubmit: String? = null
        r.host.once("prompt.submit") { params ->
            val entry = r.journal(ref).single()
            journalMethodAtSubmit = entry.method; journalTextAtSubmit = entry.text
            r.host.defaultHandle("prompt.submit", params)
        }
        val result = r.repo.send(ref, "/deploy-skill prod", selection = selection)
        assertEquals(Admission.Streaming, (result as SendResult.Admitted).admission)
        val dispatch = r.host.calls("command.dispatch").single().params
        assertEquals("deploy-skill", dispatch["name"].asString)
        assertEquals("prod", dispatch["arg"].asString)
        assertEquals(0, r.host.count("slash.exec"))
        val submit = r.host.calls("prompt.submit").single().params
        assertEquals("The expanded bytes, once", "EXPANDED(prod)", submit["text"].asString)
        assertEquals(true, submit["queued"].asBool)
        assertEquals("The journal held the changed method and bytes before they were sent", "prompt.submit", journalMethodAtSubmit)
        assertEquals("EXPANDED(prod)", journalTextAtSubmit)
        val entry = r.journal(ref).single()
        assertEquals("What the person typed survives the expansion", "/deploy-skill prod", entry.composerText)
        // Normal terminal rules from here.
        r.host.streamReply(r.runtimeOf(ref), "Deployed.")
        r.host.flush()
        r.eventually(message = "retired at terminal") { r.state(ref).unresolved.isEmpty() }
    }

    @Test fun anExplicit4018FallsBackToCommandDispatchOnceAndPersistsTheChangedMethodFirst() = run {
        val r = rig()
        val ref = r.newChat()
        var methodWhenDispatching: String? = null
        r.host.once("command.dispatch") { params ->
            methodWhenDispatching = r.journal(ref).single().method
            r.host.defaultHandle("command.dispatch", params)
        }
        val result = r.repo.send(ref, "/Deploy-Skill   prod now")
        assertTrue("$result", result is SendResult.Admitted)
        assertEquals(1, r.host.count("slash.exec"))
        assertEquals("command.dispatch", methodWhenDispatching)
        val dispatch = r.host.calls("command.dispatch").single().params
        assertEquals("The name is lowercased, the rest is the argument", "deploy-skill", dispatch["name"].asString)
        assertEquals("prod now", dispatch["arg"].asString)
    }

    @Test fun aTransportFailureNeverFallsBackToTheOtherRouteAndAnUnknownDispatchNeverReruns() = run {
        val r = rig()
        val ref = r.newChat()
        r.host.timeOutOnce("slash.exec", applyFirst = false)
        assertTrue(r.repo.send(ref, "/deploy-skill x") is SendResult.Uncertain)
        assertEquals("A timeout of slash.exec does not authorize command.dispatch", 0, r.host.count("command.dispatch"))
        assertEquals(1, r.host.count("slash.exec"))

        val other = r.newChat("scratch")
        val selection = r.repo.commands(other).selection("/deploy-skill y")!!
        r.host.timeOutOnce("command.dispatch")
        assertTrue(r.repo.send(other, "/deploy-skill y", selection = selection) is SendResult.Uncertain)
        assertEquals("An unknown dispatch is never rerun, and its text is not submitted either", 1, r.host.count("command.dispatch"))
        assertEquals(0, r.host.count("prompt.submit"))
        assertEquals("command.dispatch", r.state(other).unresolved.single().method)
    }

    @Test fun aSelectionIsCheckedAgainstTheCurrentTextSoAStaleOneNeverRuns() = run {
        val r = rig()
        val ref = r.newChat()
        val selection = r.repo.commands(ref).selection("/help")!!
        val stale = r.repo.send(ref, "/helpx now", selection = selection)
        assertEquals(ChatError.Kind.InvalidInput, (stale as SendResult.NotSent).error.kind)
        val notACommand = r.repo.send(ref, "plain words", selection = selection)
        assertEquals(ChatError.Kind.InvalidInput, (notACommand as SendResult.NotSent).error.kind)
        assertEquals(0, r.host.count("slash.exec") + r.host.count("prompt.submit") + r.host.count("command.dispatch"))
        assertTrue(r.journal(ref).isEmpty())
    }

    @Test fun theFirstTurnOfACodeChatWithALeadingSlashUsesTheSameRouterNotPlainPromptSubmit() = run {
        val r = rig()
        val ref = r.newChat("research", CreateRequest(cwd = "/home/example/project"))
        r.host.slashOutputs["plan"] = buildJsonObject { put("type", "send"); put("message", "PLAN: refactor the parser") }
        val result = r.repo.send(ref, "/plan refactor the parser")
        assertTrue("$result", result is SendResult.Admitted)
        assertEquals("/plan refactor the parser", r.host.calls("slash.exec").single().params["command"].asString)
        assertEquals("Only the expansion is ever a prompt", listOf("PLAN: refactor the parser"), r.host.calls("prompt.submit").map { it.params["text"].asString })
    }

    @Test fun theNewChatCatalogIsBoundToTheProfileAndFolderBeforeASessionExists() = run {
        val r = rig()
        val index = r.repo.commandsForNewChat("research", "/home/example/project")
        assertNotNull(index.selection("/plan"))
        val call = r.host.calls("commands.catalog").single().params
        assertEquals("research", call["profile"].asString)
        assertEquals("/home/example/project", call["cwd"].asString)
        assertFalse(call.containsKey("session_id"))
    }

    @Test fun aRejectedCommandIsADefiniteRefusalAndAnArbitraryErrorIsNot() = run {
        val r = rig()
        val ref = r.newChat()
        r.host.rejectOnce("slash.exec", 4002)
        assertTrue(r.repo.send(ref, "/help") is SendResult.Refused)
        assertEquals("/help", r.state(ref).draft)
        r.host.once("slash.exec") { throw HermesException(HermesException.Kind.RpcRejected, code = 5000) }
        assertTrue("An arbitrary host error from a mutation is not proof of non-admission", r.repo.send(ref, "/help again") is SendResult.Uncertain)
    }
}
