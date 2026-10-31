package app.bighelp.android.live

import app.bighelp.hermes.GatewayConnection
import app.bighelp.hermes.GatewayState
import app.bighelp.hermes.HermesException

/**
 * What the person is told about a computer's live connection, after setup as well as during it. It is read
 * from the gateway itself, never guessed: only a socket that is ready and advertised is [Connected].
 */
internal enum class ComputerLink {
    /** The first connection of this session is not up yet. */
    Connecting,
    Connected,

    /** The socket was lost and the gateway's own recovery is trying again. */
    Reconnecting,

    /** The connection ended and nothing is retrying; Reconnect (or coming back to the app) starts it again. */
    Offline,

    /** The host no longer accepts the saved sign-in; reconnecting cannot help until the person signs in again. */
    SignInRequired,
}

internal fun linkOf(state: GatewayState): ComputerLink = when (state.connection) {
    GatewayConnection.Connected -> ComputerLink.Connected
    GatewayConnection.Connecting -> ComputerLink.Connecting
    GatewayConnection.Recovering -> ComputerLink.Reconnecting
    GatewayConnection.Closed -> ComputerLink.Offline
    GatewayConnection.Idle -> when {
        state.lastFailure?.kind in SIGN_IN_FAILURES -> ComputerLink.SignInRequired
        // Generation 0 and no failure: the owner has not tried yet. Anything later that is idle has ended.
        state.generation == 0L && state.lastFailure == null -> ComputerLink.Connecting
        else -> ComputerLink.Offline
    }
}

private val SIGN_IN_FAILURES = setOf(HermesException.Kind.AuthenticationRequired, HermesException.Kind.InvalidCredentials)
