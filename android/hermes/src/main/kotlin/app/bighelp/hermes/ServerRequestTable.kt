package app.bighelp.hermes

/**
 * The open server requests of one socket generation: a bounded, pure table keyed by the exact request
 * ID. IDs are opaque; Kotlin strings compare by UTF-16 code units, so canonically equivalent but
 * byte-distinct IDs stay distinct and nothing is trimmed, folded or parsed. A response is cancellable
 * while queued and the request is retired immediately before its socket send.
 */
internal class ServerRequestTable {
    enum class Registration { Accepted, Duplicate, AtCapacity }

    private enum class Phase { Handling, ResponseQueued }
    private class Entry(val method: String, var phase: Phase)

    private val entries = HashMap<String, Entry>()

    val count: Int get() = entries.size

    fun contains(id: String, method: String): Boolean = entries[id]?.method == method

    fun register(id: String, method: String): Registration {
        if (entries.containsKey(id)) return Registration.Duplicate
        if (entries.size >= MAXIMUM_OPEN) return Registration.AtCapacity
        entries[id] = Entry(method, Phase.Handling)
        return Registration.Accepted
    }

    /** True only for a request still being handled whose method matches. */
    fun stageResponse(id: String, method: String): Boolean {
        val entry = entries[id] ?: return false
        if (entry.method != method || entry.phase != Phase.Handling) return false
        entry.phase = Phase.ResponseQueued
        return true
    }

    /** Retires the request right before its response is written; false if it was cancelled meanwhile. */
    fun beginSendingResponse(id: String, method: String): Boolean {
        val entry = entries[id] ?: return false
        if (entry.method != method || entry.phase != Phase.ResponseQueued) return false
        entries.remove(id)
        return true
    }

    /** A `request.cancel` retires a request only when both the ID and the method match. */
    fun retire(id: String, method: String): Boolean {
        if (entries[id]?.method != method) return false
        entries.remove(id)
        return true
    }

    fun removeAll() = entries.clear()

    companion object {
        const val MAXIMUM_OPEN = 64
    }
}
