package app.bighelp.hermes.chat

import java.util.Base64

/**
 * The app-visible identity of one conversation: the exact profile and the immutable anchor (the canonical
 * Bot Chat registry ID, the lineage root of a saved chat, or the stored ID a new chat was born with). It is
 * what the UI routes and what drafts and journals are scoped by. It never changes when the transcript's
 * stored tip moves (compaction), and it is never sent to Hermes in place of a runtime or stored ID.
 */
data class ConversationRef(val profile: String, val anchor: String) {
    init {
        require(Coordinates.isValid(profile, Coordinates.MAXIMUM_PROFILE_BYTES)) { "Invalid profile" }
        require(Coordinates.isValid(anchor)) { "Invalid anchor" }
    }

    /** A stable, URL-safe string for routing. Decodes only back to this exact pair. */
    val id: String = "c1.${encode(profile)}.${encode(anchor)}"

    override fun toString() = "ConversationRef(${id.take(24)}…)"

    companion object {
        /** The ref [id] names, or null for anything that is not exactly an ID this class produced. */
        fun parse(id: String): ConversationRef? {
            if (id.length > 4_096) return null
            val parts = id.split('.')
            if (parts.size != 3 || parts[0] != "c1") return null
            val profile = decode(parts[1]) ?: return null
            val anchor = decode(parts[2]) ?: return null
            return runCatching { ConversationRef(profile, anchor) }.getOrNull()?.takeIf { it.id == id }
        }

        private fun encode(value: String): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(value.toByteArray(Charsets.UTF_8))

        private fun decode(value: String): String? {
            if (value.isEmpty() || value.length > 1_024 || !value.all { it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_' }) return null
            val bytes = runCatching { Base64.getUrlDecoder().decode(value) }.getOrNull() ?: return null
            val text = runCatching {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                    .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
            }.getOrNull() ?: return null
            return text.takeIf { encode(it) == value }
        }
    }
}

/**
 * The coordinates of one conversation that can change, kept apart from [ref]: the stored transcript tip
 * (REST history and `session.resume` target it), the old tips that were routing aliases (a notification for
 * a former stored ID still finds this chat), and the registry facts. The runtime ID and replay epoch are
 * live facts of one connection and live in the session binding instead.
 */
class ConversationIdentity(
    val ref: ConversationRef,
    val storedTip: String,
    val formerStoredIds: List<String> = emptyList(),
    val lineageRootId: String? = null,
    val lineageIds: List<String>? = null,
    val canonicalRegistryId: String? = null,
) {
    init {
        require(Coordinates.isValid(storedTip)) { "Invalid stored tip" }
    }

    /** True for any ID this conversation has had: anchor, tip, former tips, lineage and registry IDs. Byte-exact. */
    fun knows(id: String): Boolean =
        id == ref.anchor || id == storedTip || id in formerStoredIds || id == lineageRootId || id == canonicalRegistryId ||
            lineageIds?.contains(id) == true

    /**
     * Moves the tip to [next] and keeps the old one as a routing alias (bounded, oldest dropped first).
     * Callers validate the successor first ([IdentityAdoption]); this only records it.
     */
    fun withTip(next: String): ConversationIdentity {
        if (next == storedTip) return this
        require(Coordinates.isValid(next)) { "Invalid stored tip" }
        val aliases = (formerStoredIds.filter { it != next } + storedTip).takeLast(ChatStoreLimits.MAXIMUM_FORMER_STORED_IDS)
        return ConversationIdentity(ref, next, aliases, lineageRootId, lineageIds, canonicalRegistryId)
    }

    fun withCatalog(lineageRootId: String?, lineageIds: List<String>?, canonicalRegistryId: String?) =
        ConversationIdentity(ref, storedTip, formerStoredIds, lineageRootId ?: this.lineageRootId, lineageIds ?: this.lineageIds,
            canonicalRegistryId ?: this.canonicalRegistryId)

    override fun toString() = "ConversationIdentity($ref)"
}

/**
 * Whether a different stored ID than the current tip may be adopted. A compaction successor is host data
 * and must be proved before the transcript, draft routing or a notification alias moves to it.
 */
internal object IdentityAdoption {
    enum class Evidence {
        /** `session.resume` of this conversation's own tip returned it: the host resolves a tip to its successor. */
        ResumeOfCurrentTip,

        /** `session.info.stored_session_id` from the runtime this repository holds for this conversation, same socket and epoch. */
        RuntimeReport,

        /** A REST history response for the current tip named another session ID. */
        HistoryResponse,
    }

    /**
     * @return true when [proposed] may become the tip. Resume and runtime evidence are first-hand answers
     * about this exact conversation; a history response is accepted only for an ID the catalog's lineage
     * already named or a tip that a first-hand answer proved earlier.
     */
    fun accepts(identity: ConversationIdentity, proposed: String, evidence: Evidence): Boolean {
        if (!Coordinates.isValid(proposed)) return false
        if (proposed == identity.storedTip) return true
        return when (evidence) {
            Evidence.ResumeOfCurrentTip, Evidence.RuntimeReport -> true
            Evidence.HistoryResponse -> identity.lineageIds?.contains(proposed) == true || proposed in identity.formerStoredIds
        }
    }
}
