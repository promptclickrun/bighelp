package app.bighelp.android

import app.bighelp.hermes.HermesEndpointException

/** Light, Dark, or follow the phone. Saved on the device. */
enum class Appearance { Automatic, Light, Dark }

/** Where the person is. The back stack is plain data so navigation can be tested without a device. */
sealed interface Route {
    data object Welcome : Route
    data object Consent : Route
    data object Setup : Route
    data object Sessions : Route
    data object Agents : Route
    data object Settings : Route

    /** Choosing how to sign in to the computer that was just checked. */
    data object SignIn : Route
    data object Archived : Route
    data class Chat(val sessionId: String) : Route

    /** A real chat; [refId] is `ConversationRef.id`, never an ID from the host's own wire. */
    data class LiveChat(val refId: String) : Route
}

/** What the setup screen shows for the host check. Found is never a connection. */
sealed interface DiscoveryState {
    data object Idle : DiscoveryState
    data object Checking : DiscoveryState

    /** The typed address was refused before any request; only the category is kept, never the input. */
    data class AddressProblem(val reason: HermesEndpointException.Reason) : DiscoveryState

    data class Unavailable(val address: String) : DiscoveryState

    /** The live check was refused, with the reason in plain words (a gate, a web page, a certificate...). */
    data class Refused(val message: String) : DiscoveryState
    data class Found(val address: String, val authRequired: Boolean, val browserSignIn: Boolean) : DiscoveryState
}

data class SetupState(
    val address: String = "",
    val allowPrivateHttp: Boolean = false,
    val discovery: DiscoveryState = DiscoveryState.Idle,
    /** The gate in front of the address, typed under "Extra access details". Cleared once a computer is added. */
    val access: AccessInput = AccessInput(),
)

data class DemoAgent(val id: String, val name: String, val role: String, val colorArgb: Long)

/** [isExample] marks a reply the demo wrote itself; no agent produced it. */
data class DemoMessage(val id: String, val fromUser: Boolean, val text: String, val isExample: Boolean = false)

data class DemoSession(val id: String, val agentId: String, val title: String, val messages: List<DemoMessage>)

/** Everything the sample data owns. It lives only in memory and ends with the demo. */
data class DemoState(
    val agents: List<DemoAgent>,
    val selectedAgentId: String,
    /** Most recent activity first. */
    val sessions: List<DemoSession>,
    val search: String = "",
    /** Unsent text by chat, kept while the person looks elsewhere. */
    val drafts: Map<String, String> = emptyMap(),
    val chatsStarted: Int = 0,
) {
    fun agent(id: String): DemoAgent = agents.firstOrNull { it.id == id } ?: agents.first()

    fun session(id: String): DemoSession? = sessions.firstOrNull { it.id == id }

    /** Chats matching the search box in a title, an agent's name or any message. */
    val visibleSessions: List<DemoSession>
        get() {
            val query = search.trim()
            if (query.isEmpty()) return sessions
            return sessions.filter { session ->
                session.title.contains(query, ignoreCase = true) ||
                    agent(session.agentId).name.contains(query, ignoreCase = true) ||
                    session.messages.any { it.text.contains(query, ignoreCase = true) }
            }
        }
}

data class AppState(
    val backStack: List<Route> = listOf(Route.Welcome),
    val consentGranted: Boolean = false,
    val appearance: Appearance = Appearance.Automatic,
    val setup: SetupState = SetupState(),
    /** Non-null exactly while the demo is open. */
    val demo: DemoState? = null,
    /** True while a real computer is open: the same places show its real agents and chats. */
    val live: Boolean = false,
    /** The name offered for the computer being signed in to: its address, or the saved computer's own name. */
    val signInName: String = "",
    /** What the person calls themselves, at most 40 characters. Saved on this phone. */
    val userName: String = "",
    /** Shows the host-administration rows. Everyday controls never depend on it. */
    val nerdMode: Boolean = false,
) {
    val route: Route get() = backStack.last()
}
