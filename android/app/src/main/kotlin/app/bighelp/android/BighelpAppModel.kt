package app.bighelp.android

import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.HermesEndpointException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Owns the app's state. Screens read [state] and call the actions below; nothing else changes it, and it
 * knows nothing about Android, so every rule here runs in plain JVM tests.
 *
 * Call it from one thread (the main thread in the app). Two rules matter most:
 * - **Consent first.** No host request is made, and none is even built, until [agreeToAiData].
 * - **One owner for a host check.** Any change to the typed address, the private-HTTP switch or the screen
 *   cancels the check and bumps [checkGeneration]; an answer that arrives for an older generation is
 *   dropped even if the checker ignored cancellation.
 */
class BighelpAppModel(
    private val preferences: PreviewPreferences,
    private val hostChecker: HostChecker,
    private val scope: CoroutineScope,
) {
    private val mutableState = MutableStateFlow(
        AppState(consentGranted = preferences.aiDataAgreed, appearance = preferences.appearance),
    )
    val state: StateFlow<AppState> = mutableState.asStateFlow()

    private var checkJob: Job? = null
    private var checkGeneration = 0

    // -- navigation -------------------------------------------------------------------------

    /** Pops one screen. Returns false at the root, where the system decides (leaving the app). */
    fun back(): Boolean {
        val stack = mutableState.value.backStack
        if (stack.size <= 1) return false
        if (stack.last() == Route.Setup) dropCheck()
        mutableState.update { it.copy(backStack = it.backStack.dropLast(1)) }
        return true
    }

    /** One of the menu's places: Chats, Agents or Settings. Back from any of them returns to Chats. */
    fun openPlace(place: Route) {
        if (mutableState.value.demo == null) return
        if (place != Route.Sessions && place != Route.Agents && place != Route.Settings) return
        mutableState.update {
            it.copy(backStack = if (place == Route.Sessions) listOf(Route.Sessions) else listOf(Route.Sessions, place))
        }
    }

    fun openChat(sessionId: String) {
        val demo = mutableState.value.demo ?: return
        if (demo.session(sessionId) == null || mutableState.value.route == Route.Chat(sessionId)) return
        mutableState.update { it.copy(backStack = listOf(Route.Sessions, Route.Chat(sessionId))) }
    }

    // -- connecting to a computer -----------------------------------------------------------

    fun connectComputer() {
        dropCheck()
        val next = if (mutableState.value.consentGranted) Route.Setup else Route.Consent
        mutableState.update { it.copy(backStack = listOf(Route.Welcome, next), demo = null) }
    }

    /** The one-time agreement; never asked again once given. */
    fun agreeToAiData() {
        preferences.aiDataAgreed = true
        mutableState.update { current ->
            val stack = if (current.route == Route.Consent) current.backStack.dropLast(1) + Route.Setup else current.backStack
            current.copy(consentGranted = true, backStack = stack)
        }
    }

    fun setAddress(address: String) {
        if (address == mutableState.value.setup.address) return
        dropCheck()
        mutableState.update { it.copy(setup = it.setup.copy(address = address)) }
    }

    fun setAllowPrivateHttp(allowed: Boolean) {
        if (allowed == mutableState.value.setup.allowPrivateHttp) return
        dropCheck()
        mutableState.update { it.copy(setup = it.setup.copy(allowPrivateHttp = allowed)) }
    }

    /** Asks the typed address whether a Hermes computer is there. Ignored while a check is running. */
    fun checkHost() {
        val current = mutableState.value
        if (current.setup.discovery == DiscoveryState.Checking) return
        if (!current.consentGranted) {
            // Nothing is built or sent without the agreement; show it instead.
            if (current.route != Route.Consent) {
                mutableState.update { it.copy(backStack = it.backStack.dropLast(1) + Route.Consent) }
            }
            return
        }
        val endpoint = try {
            HermesEndpoint.parse(current.setup.address.trim(), current.setup.allowPrivateHttp)
        } catch (problem: HermesEndpointException) {
            setDiscovery(DiscoveryState.AddressProblem(problem.reason))
            return
        }

        val generation = ++checkGeneration
        setDiscovery(DiscoveryState.Checking)
        checkJob = scope.launch {
            val result = hostChecker.check(endpoint, consentGranted = true)
            if (generation != checkGeneration) return@launch
            setDiscovery(
                when (result) {
                    DiscoveryResult.ConsentRequired -> DiscoveryState.Idle
                    DiscoveryResult.Unavailable -> DiscoveryState.Unavailable(endpoint.canonical)
                    is DiscoveryResult.Available ->
                        DiscoveryState.Found(endpoint.canonical, result.authRequired, result.browserSignIn)
                },
            )
        }
    }

    fun cancelCheck() = dropCheck()

    private fun setDiscovery(discovery: DiscoveryState) =
        mutableState.update { it.copy(setup = it.setup.copy(discovery = discovery)) }

    /** Cancels any check and forgets its result; a late answer can no longer be applied. */
    private fun dropCheck() {
        checkGeneration++
        checkJob?.cancel()
        checkJob = null
        if (mutableState.value.setup.discovery != DiscoveryState.Idle) setDiscovery(DiscoveryState.Idle)
    }

    // -- demo ---------------------------------------------------------------------------------

    /** Opens the sample data. It needs no agreement because nothing leaves the phone. */
    fun tryDemo() {
        dropCheck()
        mutableState.update { it.copy(backStack = listOf(Route.Sessions), demo = DemoContent.initial()) }
    }

    fun leaveDemo() {
        mutableState.update { it.copy(backStack = listOf(Route.Welcome), demo = null) }
    }

    fun selectAgent(agentId: String) = updateDemo { demo ->
        if (demo.agents.any { it.id == agentId }) demo.copy(selectedAgentId = agentId) else demo
    }

    fun setSearch(query: String) = updateDemo { it.copy(search = query) }

    /** Opens a chat with the selected agent, reusing an empty one so repeated taps never pile up. */
    fun startNewChat() {
        val demo = mutableState.value.demo ?: return
        val existing = demo.sessions.firstOrNull { it.agentId == demo.selectedAgentId && it.messages.isEmpty() }
        val created = existing ?: DemoSession(
            id = "chat-${demo.chatsStarted + 1}",
            agentId = demo.selectedAgentId,
            title = NEW_CHAT_TITLE,
            messages = emptyList(),
        )
        mutableState.update { current ->
            val currentDemo = current.demo ?: return@update current
            current.copy(
                backStack = listOf(Route.Sessions, Route.Chat(created.id)),
                demo = if (existing != null) currentDemo else currentDemo.copy(
                    sessions = listOf(created) + currentDemo.sessions,
                    chatsStarted = currentDemo.chatsStarted + 1,
                ),
            )
        }
    }

    fun setDraft(sessionId: String, text: String) = updateDemo { demo ->
        if (demo.session(sessionId) == null) demo
        else demo.copy(drafts = if (text.isEmpty()) demo.drafts - sessionId else demo.drafts + (sessionId to text))
    }

    /**
     * Sends the chat's draft: your message, then the fixed example reply, at once. Nothing is sent
     * anywhere. Returns false for a blank draft or an unknown chat.
     */
    fun send(sessionId: String): Boolean {
        var sent = false
        updateDemo { demo ->
            val session = demo.session(sessionId) ?: return@updateDemo demo
            val text = demo.drafts[sessionId].orEmpty().trim()
            if (text.isEmpty()) return@updateDemo demo
            sent = true
            val index = session.messages.size
            val updated = session.copy(
                title = if (session.messages.isEmpty()) titleFrom(text) else session.title,
                messages = session.messages + listOf(
                    DemoMessage("$sessionId/$index", fromUser = true, text = text),
                    DemoMessage(
                        "$sessionId/${index + 1}", fromUser = false,
                        text = DemoContent.exampleReply(demo.agent(session.agentId)), isExample = true,
                    ),
                ),
            )
            demo.copy(
                sessions = listOf(updated) + demo.sessions.filterNot { it.id == sessionId },
                drafts = demo.drafts - sessionId,
            )
        }
        return sent
    }

    private fun updateDemo(change: (DemoState) -> DemoState) {
        mutableState.update { current -> current.demo?.let { current.copy(demo = change(it)) } ?: current }
    }

    private fun titleFrom(message: String): String {
        val line = message.lineSequence().first().trim()
        if (line.length <= MAXIMUM_TITLE) return line
        // Step back one unit when the cut would leave half of an emoji (a surrogate pair) behind.
        val cut = if (line[MAXIMUM_TITLE - 1].isHighSurrogate()) MAXIMUM_TITLE - 1 else MAXIMUM_TITLE
        return line.take(cut).trimEnd() + "…"
    }

    // -- settings -----------------------------------------------------------------------------

    fun setAppearance(appearance: Appearance) {
        preferences.appearance = appearance
        mutableState.update { it.copy(appearance = appearance) }
    }

    companion object {
        const val NEW_CHAT_TITLE = "New chat"
        private const val MAXIMUM_TITLE = 40
    }
}
