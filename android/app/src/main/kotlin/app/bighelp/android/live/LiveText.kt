package app.bighelp.android.live

import app.bighelp.hermes.HermesException
import app.bighelp.hermes.chat.ChatError
import app.bighelp.hermes.chat.SendBlock

/**
 * Every sentence the live screens show about a failure or a state, in plain words. A missing host feature says
 * to update the plugin; nothing names an AI company, an account system or a raw code.
 */
internal object LiveText {
    fun describe(error: ChatError): String = when (error.kind) {
        ChatError.Kind.NotConnected -> "Not connected to your computer right now."
        ChatError.Kind.HostUnavailable -> "Your computer isn't answering right now."
        ChatError.Kind.SignInRequired -> "Your computer wants you to sign in again."
        ChatError.Kind.NotOpen -> "This chat isn't open any more. Go back and open it again."
        ChatError.Kind.NoLiveSession -> "This chat isn't running on your computer. Open it again."
        ChatError.Kind.PersistenceFailed -> "This phone couldn't save your message, so nothing was sent."
        ChatError.Kind.InvalidResponse -> "Your computer answered in a way this app doesn't understand."
        ChatError.Kind.Rejected -> "Your computer said no to that."
        ChatError.Kind.TooLarge -> "That is too long to send."
        ChatError.Kind.Unsupported -> "Your computer doesn't offer this yet. You may need to update the plugin on your computer."
        ChatError.Kind.HistoryChanged -> "This chat changed on your computer, so it was loaded again."
        ChatError.Kind.ModelNotConfirmed -> "The chat didn't confirm the new model."
        ChatError.Kind.WorkspaceNotConfirmed -> "The chat didn't confirm the folder."
        ChatError.Kind.CreationUnconfirmed -> "We couldn't confirm the new chat was made."
        ChatError.Kind.CreationInProgress -> "A new chat for this agent is already being made."
        ChatError.Kind.OutcomeUnknown -> "We couldn't tell whether that worked. Check before you try again."
        ChatError.Kind.Conflict -> "That can't be done while the chat is busy."
        ChatError.Kind.InvalidInput -> "That can't be sent."
        ChatError.Kind.NoActiveTurn -> "Nothing is running to steer."
        ChatError.Kind.Cancelled -> "That was cancelled."
    }

    /** A failure of setup, sign-in or reconnecting. [HermesException.message] is only the kind name, so this is the one place words come from. */
    fun describe(kind: HermesException.Kind): String = when (kind) {
        HermesException.Kind.InvalidEndpoint -> "That address can't be used. Check it and try again."
        HermesException.Kind.PlaintextNotAllowed -> "Plain http:// only works inside your own network. Use https:// instead."
        HermesException.Kind.InvalidCredentials -> "Those details weren't accepted. Check them and sign in again."
        HermesException.Kind.AuthenticationRequired -> "Your computer wants you to sign in again."
        HermesException.Kind.UnsupportedAuthentication -> "This computer doesn't offer that way of signing in."
        HermesException.Kind.AmbiguousPasswordProvider -> "This computer has more than one password sign-in. Pick one."
        HermesException.Kind.AuthModeChanged -> "This computer changed how it signs people in. Start again to check."
        HermesException.Kind.IdentityChanged -> "That is a different sign-in than the one saved for this computer."
        HermesException.Kind.SavedConnectionInvalid -> "The sign-in saved on this phone can't be read. Sign in again."
        HermesException.Kind.SecureStorageUnavailable -> "This phone's secure storage isn't available right now."
        HermesException.Kind.SecureStorageChanged -> "The saved sign-in changed in the background. Try again."
        HermesException.Kind.RedirectRefused -> "This address sent the app somewhere else, so it was stopped."
        HermesException.Kind.InvalidResponse -> "That address didn't answer like a Hermes computer."
        HermesException.Kind.MessageTooLarge -> "Your computer sent more than this app accepts."
        HermesException.Kind.TooManyRequests -> "Too many things were happening at once. Try again."
        HermesException.Kind.NotConnected -> "Not connected to your computer right now."
        HermesException.Kind.ConnectionFailed -> "Couldn't reach this computer. Check the address and your network."
        HermesException.Kind.TlsRequired -> "The secure connection to this address couldn't be trusted."
        HermesException.Kind.RateLimited -> "Your computer asked the app to slow down. Try again in a moment."
        HermesException.Kind.ServerUnavailable -> "Your computer isn't answering right now."
        HermesException.Kind.BrowserAuthenticationUnavailable -> "The browser sign-in couldn't start."
        HermesException.Kind.NativeTokenExchangeUncertain -> "The sign-in may have gone through, but the answer was lost. Try signing in again."
        HermesException.Kind.InvalidAccessCredentials -> "Those access details can't be used with this address."
        HermesException.Kind.CloudflareAccessDenied -> "The access details were refused. Check the access details."
        HermesException.Kind.HostNameRefused -> "This address was refused."
        HermesException.Kind.WebPageInsteadOfHermes -> "That address is a web page, not a Hermes computer."
        HermesException.Kind.Disconnected -> "The connection dropped."
        HermesException.Kind.TimedOut -> "Your computer took too long to answer."
        HermesException.Kind.Cancelled -> "That was cancelled."
        HermesException.Kind.RpcRejected -> "Your computer said no to that."
        HermesException.Kind.ActiveSessionLimit -> "Your computer has too many chats running. Close one and try again."
        HermesException.Kind.ExclusiveSubmitUnavailable -> "Your computer can't take new messages safely yet. You may need to update the plugin."
        HermesException.Kind.OutcomeUnknown -> "We couldn't tell whether that worked."
    }

    fun problem(problem: ComputerProblem): String = when (problem) {
        ComputerProblem.Connection -> "Couldn't connect to this computer."
        ComputerProblem.StorageUnavailable -> "This phone couldn't save or read its stored data right now."
        ComputerProblem.UnreadableStorage -> "Saved data on this phone can't be read. You can sign in again."
        ComputerProblem.AlreadyConfigured -> "This computer and sign-in are already saved."
        ComputerProblem.ComputerLimit -> "You can save up to 32 computers. Remove one first."
        ComputerProblem.InvalidName -> "Give the computer a short name, with no line breaks."
    }

    fun sendBlock(block: SendBlock): String = when (block) {
        SendBlock.Opening -> "Opening this chat…"
        SendBlock.NotConnected -> "Not connected to your computer right now."
        SendBlock.CatchingUp -> "Catching up with your computer…"
        SendBlock.RecoveryRequired -> "Reconnecting this chat…"
        SendBlock.PendingAdmission -> "Waiting for your computer to take the last message…"
        SendBlock.HostLacksExclusiveSubmit -> "Your computer can't take new messages safely yet. You may need to update the plugin."
        SendBlock.TooManyUnresolved -> "Review the earlier messages above before sending more."
        SendBlock.NoLiveSession -> "This chat isn't running. Open it again."
    }

    /** The banner above a screen; null while all is well. */
    fun link(link: ComputerLink?): String? = when (link) {
        null, ComputerLink.Connected -> null
        ComputerLink.Connecting -> "Connecting…"
        ComputerLink.Reconnecting -> "Reconnecting…"
        ComputerLink.Offline -> "Not connected."
        ComputerLink.SignInRequired -> "Sign in again to keep going."
    }
}
