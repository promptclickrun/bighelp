package app.bighelp.android

import app.bighelp.android.live.ComputerPhase
import app.bighelp.android.live.LiveModel
import app.bighelp.android.live.SetupOutcome
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.HermesEndpointException
import app.bighelp.hermes.SignInInput
import app.bighelp.hermes.chat.ConversationRef
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
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
 *
 * With a [live] model the same places show a real computer: its connection decides when the app is "live"
 * (a computer is open) and when it leaves (the computer is gone), and the host check is the real, gate-aware
 * discovery rather than the public status probe. Without one (tests, the demo alone) nothing live exists.
 */
class BighelpAppModel internal constructor(
    private val preferences: PreviewPreferences,
    private val hostChecker: HostChecker,
    private val scope: CoroutineScope,
    internal val live: LiveModel<*>?,
) {
    constructor(preferences: PreviewPreferences, hostChecker: HostChecker, scope: CoroutineScope) :
        this(preferences, hostChecker, scope, null)

    private val mutableState = MutableStateFlow(
        AppState(
            consentGranted = preferences.aiDataAgreed, appearance = preferences.appearance,
            userName = preferences.userName, nerdMode = preferences.nerdMode,
        ),
    )
    val state: StateFlow<AppState> = mutableState.asStateFlow()

    private var checkJob: Job? = null
    private var checkGeneration = 0
    private var lastActiveComputer: UUID? = null

    init {
        live?.let { model ->
            scope.launch {
                combine(model.connections.state, model.connections.active) { connection, active -> connection.phase to active?.computer?.id }
                    .collect { (phase, activeId) -> onConnection(phase, activeId) }
            }
        }
    }

    /** A real computer opening shows its places; it going away (and not being replaced) leaves them. */
    private fun onConnection(phase: ComputerPhase, activeId: UUID?) {
        mutableState.update { current ->
            when {
                activeId != null && (!current.live || activeId != lastActiveComputer || current.route in COMPUTER_SETUP_ROUTES) -> {
                    lastActiveComputer = activeId
                    current.copy(live = true, demo = null, backStack = listOf(Route.Sessions), setup = SetupState())
                }
                // Not while the person is adding a computer: a refused check there leaves them on that screen.
                activeId == null && current.live && phase in COMPUTER_GONE && current.route !in ON_SETUP_ROUTES -> {
                    lastActiveComputer = null
                    current.copy(live = false, backStack = listOf(Route.Welcome))
                }
                else -> current
            }
        }
    }

    // -- navigation -------------------------------------------------------------------------

    /** Pops one screen. Returns false at the root, where the system decides (leaving the app). */
    fun back(): Boolean {
        val stack = mutableState.value.backStack
        if (stack.size <= 1) return false
        when (val top = stack.last()) {
            Route.Setup -> {
                dropCheck()
                // Typed gate secrets do not linger once the screen they were typed on is gone.
                mutableState.update { it.copy(setup = it.setup.copy(access = AccessInput())) }
            }
            Route.SignIn -> {
                live?.cancelSetup()
                setDiscovery(DiscoveryState.Idle)
            }
            is Route.LiveChat -> leaveLiveChat(top)
            else -> Unit
        }
        mutableState.update { it.copy(backStack = it.backStack.dropLast(1)) }
        return true
    }

    /** One of the menu's places: Chats, Agents or Settings. Back from any of them returns to Chats. */
    fun openPlace(place: Route) {
        val current = mutableState.value
        if (current.demo == null && !current.live) return
        if (place != Route.Sessions && place != Route.Agents && place != Route.Settings) return
        (current.route as? Route.LiveChat)?.let(::leaveLiveChat)
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
        // From Settings of an open computer, adding another goes on top of it; from Welcome it starts the list.
        mutableState.update {
            if (it.live) it.copy(backStack = it.backStack + next) else it.copy(backStack = listOf(Route.Welcome, next), demo = null)
        }
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

    fun setAccess(access: AccessInput) {
        if (access == mutableState.value.setup.access) return
        dropCheck()
        mutableState.update { it.copy(setup = it.setup.copy(access = access)) }
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

        if (live != null) {
            startLiveCheck(live, endpoint)
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

    /** The real check: discovery through the authenticator, with the person's access details, owned by the connection. */
    private fun startLiveCheck(live: LiveModel<*>, endpoint: HermesEndpoint) {
        val access = when (val built = mutableState.value.setup.access.build()) {
            is AccessBuild.Invalid -> {
                setDiscovery(DiscoveryState.Refused(describe(built.problem)))
                return
            }
            is AccessBuild.Ok -> built.setup
        }
        val generation = ++checkGeneration
        setDiscovery(DiscoveryState.Checking)
        checkJob = scope.launch {
            val outcome = live.beginSetup(endpoint, access)
            if (generation != checkGeneration) return@launch
            if (outcome is SetupOutcome.Ready) mutableState.update { it.copy(signInName = defaultComputerName(endpoint)) }
            setDiscovery(
                when (outcome) {
                    is SetupOutcome.Ready -> DiscoveryState.Found(endpoint.canonical, outcome.status.authRequired, outcome.status.supportsNativePkce)
                    is SetupOutcome.Failed -> DiscoveryState.Refused(outcome.message)
                    SetupOutcome.Cancelled -> DiscoveryState.Idle
                },
            )
        }
    }

    /** After a found computer: choose how to sign in. The check's own session carries on to the sign-in. */
    fun continueToSignIn() {
        val current = mutableState.value
        if (live == null || current.setup.discovery !is DiscoveryState.Found || current.route == Route.SignIn) return
        mutableState.update { it.copy(backStack = it.backStack + Route.SignIn) }
    }

    /** [name] is what the person calls this computer; the coordinator checks it. Success is seen as [AppState.live]. */
    fun signIn(name: String, input: SignInInput) {
        live?.signIn(name, input)
    }

    /** The open computer's sign-in ended (the host refused it): find out how it signs in, then ask. */
    fun signInAgainSelected() {
        live?.connections?.state?.value?.selectedID?.let(::signInAgain)
    }

    fun openArchived() {
        if (!mutableState.value.live || mutableState.value.route == Route.Archived) return
        mutableState.update { it.copy(backStack = it.backStack + Route.Archived) }
    }

    /** A saved computer whose sign-in ended: find out how it signs in, then ask. */
    fun signInAgain(id: UUID) {
        val model = live ?: return
        scope.launch {
            model.reauthenticate(id).join()
            if (model.connections.state.value.phase == ComputerPhase.SignIn) {
                val name = model.connections.state.value.computers.firstOrNull { it.id == id }?.name.orEmpty()
                mutableState.update { current ->
                    val next = current.copy(signInName = name)
                    if (current.route == Route.SignIn) next else next.copy(backStack = current.backStack + Route.SignIn)
                }
            } else {
                model.notify(model.connections.state.value.authFailure?.let(app.bighelp.android.live.LiveText::describe) ?: "Couldn't reach this computer.")
            }
        }
    }

    // -- live chats ------------------------------------------------------------------------------

    /** Opens a real chat. A null ref (an ID this app did not make) opens nothing. */
    fun openLiveChat(ref: ConversationRef?) {
        val model = live ?: return
        if (ref == null || !mutableState.value.live || mutableState.value.route == Route.LiveChat(ref.id)) return
        mutableState.update { it.copy(backStack = listOf(Route.Sessions, Route.LiveChat(ref.id))) }
        scope.launch { model.openChat(ref) }
    }

    /** A new chat with the agent new chats start with; opens it once the host made it. */
    fun startLiveChat(profile: String? = null) {
        val model = live ?: return
        scope.launch {
            val agent = profile ?: model.selectedAgentId.value ?: return@launch model.notify("Pick an agent first.")
            openLiveChat(model.newChat(agent))
        }
    }

    fun openBotChat(profile: String) {
        val model = live ?: return
        scope.launch { openLiveChat(model.openBotChat(profile)) }
    }

    private fun leaveLiveChat(route: Route.LiveChat) {
        val model = live ?: return
        val ref = ConversationRef.parse(route.refId) ?: return
        scope.launch { model.leaveChat(ref) }
    }

    private fun setDiscovery(discovery: DiscoveryState) =
        mutableState.update { it.copy(setup = it.setup.copy(discovery = discovery)) }

    /** Cancels any check and forgets its result; a late answer can no longer be applied. */
    private fun dropCheck() {
        checkGeneration++
        checkJob?.cancel()
        checkJob = null
        if (mutableState.value.setup.discovery != DiscoveryState.Idle) {
            // A live check owns a session of its own; ending the check ends that session too.
            if (live != null) live.cancelSetup()
            setDiscovery(DiscoveryState.Idle)
        }
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

    /** One line of at most 40 characters. Saved on this phone; the host does not get it yet. */
    fun setUserName(text: String) {
        val flat = text.map { if (Character.isISOControl(it)) ' ' else it }.joinToString("").trim()
        val name = if (flat.codePointCount(0, flat.length) <= MAXIMUM_NAME) flat
            else flat.substring(0, flat.offsetByCodePoints(0, MAXIMUM_NAME)).trimEnd()
        preferences.userName = name
        mutableState.update { it.copy(userName = name) }
    }

    fun setNerdMode(on: Boolean) {
        preferences.nerdMode = on
        mutableState.update { it.copy(nerdMode = on) }
    }

    companion object {
        const val NEW_CHAT_TITLE = "New chat"
        private const val MAXIMUM_TITLE = 40
        private const val MAXIMUM_NAME = 40
        private val COMPUTER_GONE = setOf(ComputerPhase.Idle, ComputerPhase.Failed, ComputerPhase.SignInRequired, ComputerPhase.ConsentRequired)
        private val COMPUTER_SETUP_ROUTES = setOf<Route>(Route.Welcome, Route.Setup, Route.SignIn, Route.Consent)
        private val ON_SETUP_ROUTES = setOf<Route>(Route.Setup, Route.SignIn, Route.Consent)
    }
}
