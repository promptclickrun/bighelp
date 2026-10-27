package app.bighelp.android

import android.content.Context
import androidx.core.content.edit

/**
 * Ordinary preferences kept on the device: the one-time AI data agreement, the look, the person's name and
 * Nerd Mode. No credential, address or chat is here: sign-ins, gate details and chat records live in their own
 * stores. Backup and device transfer are excluded in the manifest.
 */
interface PreviewPreferences {
    var aiDataAgreed: Boolean
    var appearance: Appearance

    /** The person's own name, at most 40 characters. */
    var userName: String
        get() = ""
        set(@Suppress("UNUSED_PARAMETER") value) {}

    /** Settings > Nerd Mode: shows the host-administration rows. */
    var nerdMode: Boolean
        get() = false
        set(@Suppress("UNUSED_PARAMETER") value) {}
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

    override var userName: String
        get() = preferences.getString(NAME_KEY, null).orEmpty()
        set(value) = preferences.edit { putString(NAME_KEY, value) }

    override var nerdMode: Boolean
        get() = preferences.getBoolean(NERD_KEY, false)
        set(value) = preferences.edit { putBoolean(NERD_KEY, value) }

    private companion object {
        const val FILE = "bighelp_preview"

        /** The same key as the iPhone app. Never rename: a new key would ask everyone again. */
        const val AGREED_KEY = "bighelp.privacy.ai-data-agreed"
        const val APPEARANCE_KEY = "bighelp.appearance"
        const val NAME_KEY = "bighelp.user-name"
        const val NERD_KEY = "bighelp.nerd-mode"
    }
}
