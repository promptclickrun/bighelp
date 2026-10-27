package app.bighelp.android

import android.content.ActivityNotFoundException
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

/** Keeps the app's state across rotation. The model itself is plain Kotlin, tested without Android. */
class BighelpViewModel(preferences: PreviewPreferences, hostChecker: HostChecker) : ViewModel() {
    val model = BighelpAppModel(preferences, hostChecker, viewModelScope)
}

class MainActivity : ComponentActivity() {
    private val viewModel: BighelpViewModel by viewModels {
        object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T =
                BighelpViewModel(SharedPreviewPreferences(applicationContext), HostDiscovery()) as T
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
