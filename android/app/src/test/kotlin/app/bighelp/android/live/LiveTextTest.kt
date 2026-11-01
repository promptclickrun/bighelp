package app.bighelp.android.live

import app.bighelp.hermes.HermesException
import app.bighelp.hermes.chat.ChatError
import app.bighelp.hermes.chat.SendBlock
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveTextTest {
    private val banned = listOf("openai", "anthropic", "gpt", "claude", "bighelp account", "link account", "exception")

    @Test fun everyMessageIsPlainWordsWithoutProviderNamesAccountsOrCodes() {
        val texts = ChatError.Kind.entries.map { LiveText.describe(ChatError(it)) } +
            HermesException.Kind.entries.map { LiveText.describe(it) } +
            SendBlock.entries.map { LiveText.sendBlock(it) } +
            ComputerLink.entries.mapNotNull { LiveText.link(it) } +
            ComputerProblem.entries.map { LiveText.problem(it) }
        for (text in texts) {
            assertTrue("A message is never empty", text.isNotBlank())
            assertTrue("A message ends like a sentence: $text", text.last() in ".…?")
            for (word in banned) assertFalse("'$text' mentions '$word'", text.lowercase().contains(word))
        }
    }

    @Test fun aMissingHostFeatureSaysToUpdateThePluginAndNothingIsCalledAnError() {
        assertTrue(LiveText.describe(ChatError(ChatError.Kind.Unsupported)).contains("update the plugin", ignoreCase = true))
        assertFalse(LiveText.describe(ChatError(ChatError.Kind.Unsupported)).contains("error", ignoreCase = true))
    }

    @Test fun aRefusedSignInAndAGatePointAtTheRightFix() {
        assertTrue(LiveText.describe(HermesException.Kind.InvalidCredentials).contains("sign", ignoreCase = true))
        assertTrue(LiveText.describe(HermesException.Kind.CloudflareAccessDenied).contains("access", ignoreCase = true))
        assertTrue(LiveText.describe(HermesException.Kind.PlaintextNotAllowed).contains("https", ignoreCase = true))
    }

    @Test fun theConnectionBannerSaysNothingWhileConnected() {
        assertTrue(LiveText.link(ComputerLink.Connected) == null)
        assertTrue(LiveText.link(null) == null)
        assertTrue(LiveText.link(ComputerLink.Reconnecting)!!.contains("reconnect", ignoreCase = true))
    }
}
