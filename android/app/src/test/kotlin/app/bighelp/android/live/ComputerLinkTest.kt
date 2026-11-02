package app.bighelp.android.live

import app.bighelp.hermes.GatewayConnection
import app.bighelp.hermes.GatewayState
import app.bighelp.hermes.HermesException
import org.junit.Assert.assertEquals
import org.junit.Test

class ComputerLinkTest {
    private fun state(connection: GatewayConnection, generation: Long = 1, failure: HermesException.Kind? = null) =
        GatewayState(connection, generation, null, null, null, false, failure?.let { HermesException(it) })

    @Test fun onlyAReadyGatewayIsConnected() {
        assertEquals(ComputerLink.Connected, linkOf(state(GatewayConnection.Connected)))
        assertEquals(ComputerLink.Connecting, linkOf(state(GatewayConnection.Connecting)))
        assertEquals(ComputerLink.Reconnecting, linkOf(state(GatewayConnection.Recovering, failure = HermesException.Kind.Disconnected)))
    }

    @Test fun aGatewayThatNeverConnectedIsStillConnectingNotOffline() {
        assertEquals(ComputerLink.Connecting, linkOf(state(GatewayConnection.Idle, generation = 0)))
    }

    @Test fun aConnectionThatEndedAndIsNotRecoveringIsOfflineSoTheScreenOffersReconnect() {
        assertEquals(ComputerLink.Offline, linkOf(state(GatewayConnection.Idle, 3, HermesException.Kind.Disconnected)))
        assertEquals(ComputerLink.Offline, linkOf(state(GatewayConnection.Idle, 3)))
        assertEquals(ComputerLink.Offline, linkOf(state(GatewayConnection.Closed, 3)))
    }

    @Test fun aRefusedSignInIsNotMistakenForAnOutage() {
        assertEquals(ComputerLink.SignInRequired, linkOf(state(GatewayConnection.Idle, 2, HermesException.Kind.AuthenticationRequired)))
        assertEquals(ComputerLink.SignInRequired, linkOf(state(GatewayConnection.Idle, 2, HermesException.Kind.InvalidCredentials)))
        assertEquals(ComputerLink.Offline, linkOf(state(GatewayConnection.Idle, 2, HermesException.Kind.ServerUnavailable)))
    }
}
