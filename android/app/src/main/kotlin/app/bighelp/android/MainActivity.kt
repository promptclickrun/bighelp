package app.bighelp.android

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.core.net.toUri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.CreationExtras
import app.bighelp.android.live.AndroidAccessSetupStore
import app.bighelp.android.live.AndroidComputerLocalData
import app.bighelp.android.live.AndroidCredentialStore
import app.bighelp.android.live.ComputerConnectionModel
import app.bighelp.android.live.LiveModel
import app.bighelp.android.live.NetworkComputerSession
import app.bighelp.android.live.RepositoryChatService
import app.bighelp.android.live.SavedComputerStore
import app.bighelp.android.storage.AndroidChatStore
import app.bighelp.hermes.BrowserLauncher

/**
 * Keeps the app's state across rotation. The models themselves are plain Kotlin, tested without Android; this
 * is the one place the real stores, the network session and the system browser are put together. The
 * connection is closed (letting a refresh that is already running finish and save) when the app is finished.
 */
internal class BighelpViewModel(context: Context, preferences: PreviewPreferences, hostChecker: HostChecker) : ViewModel() {
    private val live: LiveModel<NetworkComputerSession>
    val model: BighelpAppModel

    init {
        val app = context.applicationContext
        val chatStore = AndroidChatStore.create(app)
        // Handing the page to the browser is all the sign-in needs from here. The answer comes back through the
        // listener the sign-in itself opens on this phone, never through the browser or a custom link.
        val browser = BrowserLauncher { url ->
            app.startActivity(Intent(Intent.ACTION_VIEW, url.toUri()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        val connections = ComputerConnectionModel(
            SavedComputerStore.create(app),
            { id -> AndroidCredentialStore.create(app, id) },
            { preferences.aiDataAgreed },
            viewModelScope,
            AndroidComputerLocalData(AndroidAccessSetupStore.create(app), chatStore),
        ) { id, endpoint, access, credentials, scope ->
            NetworkComputerSession(id, endpoint, access, credentials, scope, browser, chatStore)
        }
        live = LiveModel(connections, { RepositoryChatService(it.chat) }, viewModelScope)
        model = BighelpAppModel(preferences, hostChecker, viewModelScope, live)
        live.start()
    }

    override fun onCleared() {
        live.connections.close()
    }
}

class MainActivity : ComponentActivity() {
    private val viewModel: BighelpViewModel by viewModels {
        object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T =
                BighelpViewModel(applicationContext, SharedPreviewPreferences(applicationContext), HostDiscovery()) as T
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val versionName = packageManager.getPackageInfo(packageName, 0).versionName.orEmpty()
        setContent {
            BighelpApp(
                model = viewModel.model,
                versionName = versionName,
                onOpenPrivacyPolicy = ::openPrivacyPolicy,
            )
        }
    }

    private fun openPrivacyPolicy() {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, PRIVACY_POLICY_URL.toUri()))
        } catch (_: ActivityNotFoundException) {
            // No browser installed: the page simply can't open.
        }
    }

    private companion object {
        const val PRIVACY_POLICY_URL = "https://bighelp.app/privacy"
    }
}
