package app.bighelp.android

import android.content.Context
import androidx.core.content.edit

/**
 * The only things this milestone keeps on the device: the one-time AI data agreement and the look. No
 * credential, address or chat is stored. Backup and device transfer are excluded in the manifest.
 */
interface PreviewPreferences {
    var aiDataAgreed: Boolean
    var appearance: Appearance
}

class SharedPreviewPreferences(context: Context) : PreviewPreferences {
    private val preferences = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override var aiDataAgreed: Boolean
        get() = preferences.getBoolean(AGREED_KEY, false)
        set(value) = preferences.edit { putBoolean(AGREED_KEY, value) }

    override var appearance: Appearance
        get() = Appearance.entries.firstOrNull { it.name == preferences.getString(APPEARANCE_KEY, null) }
            ?: Appearance.Automatic
        set(value) = preferences.edit { putString(APPEARANCE_KEY, value.name) }

    private companion object {
        const val FILE = "bighelp_preview"

        /** The same key as the iPhone app. Never rename: a new key would ask everyone again. */
        const val AGREED_KEY = "bighelp.privacy.ai-data-agreed"
        const val APPEARANCE_KEY = "bighelp.appearance"
    }
}
