package app.bighelp.hermes.chat

import kotlinx.coroutines.CompletableDeferred

/**
 * A store whose next journal write waits for the test. It holds the sender between its ownership check and the
 * request, which is the window in which the socket (or the caller) can change under it.
 */
internal class GatedChatStore : MemoryChatStore() {
    @Volatile private var armed = false
    val reached = CompletableDeferred<Unit>()
    private val release = CompletableDeferred<Unit>()

    /** The next commit that writes a journal entry stops before it is applied. */
    fun holdNextJournalWrite() { armed = true }

    fun open() { release.complete(Unit) }

    override suspend fun commit(ops: List<StoreOp>) {
        if (armed && ops.any { it is StoreOp.Put && it.key.kind == RecordKind.Journal }) {
            armed = false
            reached.complete(Unit)
            release.await()
        }
        super.commit(ops)
    }
}
