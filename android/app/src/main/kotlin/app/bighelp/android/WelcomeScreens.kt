package app.bighelp.android

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/** First screen: the demo works with nothing set up; connecting signs in to a real computer. [extra] shows saved computers. */
@Composable
fun WelcomeScreen(onTryDemo: () -> Unit, onConnect: () -> Unit, extra: @Composable () -> Unit = {}) {
    ScrollingPage(Modifier.fillMaxSize().safeDrawingPadding().testTag("screen.welcome")) {
        NoodleMark(height = 96.dp)
        Spacer(Modifier.height(16.dp))
        Text("bighelp", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text(
            "Text your own AI agents, like texting a friend.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(32.dp))
        extra()
        InkButton("Try the demo", onTryDemo, tag = "welcome.demo")
        Spacer(Modifier.height(6.dp))
        Text(
            "Sample chats that stay on this phone.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(24.dp))
        InkOutlinedButton("Connect your computer", onConnect, tag = "welcome.connect")
        Spacer(Modifier.height(6.dp))
        Text(
            "Sign in to your Hermes computer and chat with your own agents.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

/** The one-time agreement. Nothing reaches a computer before it is given. */
@Composable
fun ConsentScreen(onAgree: () -> Unit, onNotNow: () -> Unit, onPrivacyPolicy: () -> Unit) {
    ScrollingPage(Modifier.fillMaxSize().safeDrawingPadding().testTag("screen.consent")) {
        Icon(
            Icons.Outlined.Lock,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(bottom = 4.dp),
        )
        Spacer(Modifier.height(12.dp))
        Text(
            "Your data and AI",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            "bighelp is a window onto the Hermes computer you choose. What you share in chat, like " +
                "messages, files or voice, goes to that computer and on to the AI providers you set up there.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            "Nothing is sent until you agree. Your sign-in stays on this phone, sealed.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(28.dp))
        InkButton("Agree and continue", onAgree, tag = "consent.agree")
        TextButton(onClick = onPrivacyPolicy, modifier = Modifier.testTag("consent.privacy")) {
            Text("Privacy policy")
        }
        TextButton(onClick = onNotNow, modifier = Modifier.testTag("consent.not-now")) { Text("Not now") }
    }
}
