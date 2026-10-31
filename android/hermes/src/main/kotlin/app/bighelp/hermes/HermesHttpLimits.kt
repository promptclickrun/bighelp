package app.bighelp.hermes

import kotlinx.serialization.json.JsonElement

/** Byte and time budgets of the shared HTTP boundary. Route ceilings cap what a caller may ask for. */
object HermesHttpLimits {
    const val DEFAULT_RESPONSE_BYTES = 1_048_576
    const val MAXIMUM_BODY_BYTES = 1_048_576
    const val DEFAULT_TIMEOUT_MILLIS = 20_000L
    const val LONGEST_REQUEST_MILLIS = 75_000L
    const val CONNECTIONS_PER_HOST = 4
    const val MAXIMUM_SESSION_TRANSFER_BYTES = 25 * 1_024 * 1_024
    const val MAXIMUM_MANAGED_FILE_LISTING_BYTES = 4 * 1_024 * 1_024
    const val MAXIMUM_MCP_TOOL_LIST_BYTES = 16 * 1_024 * 1_024

    /** A 25 MiB file as base64 inside a small JSON envelope. */
    const val MAXIMUM_MEDIA_RESPONSE_BYTES = ((25 * 1_024 * 1_024 + 2) / 3) * 4 + 8_192
    const val MAXIMUM_VOICE_TRANSCRIPTION_REQUEST_BYTES = ((25 * 1_024 * 1_024 + 2) / 3) * 4 + 8_192
    const val MAXIMUM_VOICE_SPEECH_RESPONSE_BYTES = ((8 * 1_024 * 1_024 + 2) / 3) * 4 + 8_192

    private const val NATIVE = "/api/plugins/loopdy/native"
    private val nativeFileResponseLimits = mapOf(
        "$NATIVE/attachments/fetch" to 4 * 1_024 * 1_024 + 65_536,
        "$NATIVE/image-drafts/source" to 4 * 1_024 * 1_024 + 65_536,
        "$NATIVE/board/media" to 12 * 1_024 * 1_024,
        "$NATIVE/workspace-files/read" to MAXIMUM_MEDIA_RESPONSE_BYTES,
    )

    fun clampTimeoutMillis(millis: Long): Long = millis.coerceIn(1_000L, LONGEST_REQUEST_MILLIS)

    /** The most a caller may ask for on this route, by method and query. Everything else is 4 MiB. */
    fun responseCeiling(route: String, method: String, query: List<Pair<String, String>>): Int {
        if ((method == "POST" && route.startsWith("/api/mcp/servers/") && route.endsWith("/test")) ||
            (method == "GET" && route.startsWith("/api/mcp/oauth/flows/"))
        ) return MAXIMUM_MCP_TOOL_LIST_BYTES
        if (method == "POST" && route == "/api/audio/speak") return MAXIMUM_VOICE_SPEECH_RESPONSE_BYTES
        if (method == "POST" && query.isEmpty()) nativeFileResponseLimits[route]?.let { return it }
        if (method == "GET" && route == "/api/files") return MAXIMUM_MANAGED_FILE_LISTING_BYTES
        if (method == "GET" && isSessionExportRoute(route)) return MAXIMUM_SESSION_TRANSFER_BYTES
        val paths = query.filter { it.first == "path" }
        if (method == "GET" && paths.size == 1) {
            val path = paths.single().second
            if ((route == "/api/media" && isImagePath(path)) || (route == "/api/files/read" && isDeliveredFilePath(path))) {
                return MAXIMUM_MEDIA_RESPONSE_BYTES
            }
        }
        return HermesWire.MAXIMUM_MESSAGE_BYTES
    }

    fun requestBodyLimit(route: String, method: String): Int {
        if (method != "POST") return MAXIMUM_BODY_BYTES
        return when (route) {
            "/api/sessions/import" -> MAXIMUM_SESSION_TRANSFER_BYTES
            "/api/audio/transcribe" -> MAXIMUM_VOICE_TRANSCRIPTION_REQUEST_BYTES
            else -> MAXIMUM_BODY_BYTES
        }
    }

    private fun isSessionExportRoute(route: String): Boolean {
        val prefix = "/api/sessions/"
        val suffix = "/export"
        if (!route.startsWith(prefix) || !route.endsWith(suffix) || route.length <= prefix.length + suffix.length) return false
        return '/' !in route.substring(prefix.length, route.length - suffix.length)
    }

    private val imageExtensions = setOf("png", "jpg", "jpeg", "gif", "webp", "bmp", "ico")
    private val videoExtensions = setOf("mp4", "m4v", "mov", "webm")
    private val deliveredExtensions = videoExtensions + setOf(
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "csv", "tsv",
        "rtf", "odt", "ods", "odp", "epub", "zip", "mp3", "m4a", "wav", "ogg", "flac", "aac",
    )

    /** Hermes output images: an absolute, inert path with an image extension. */
    fun isImagePath(path: String) = isOutputPath(path) && extension(path) in imageExtensions

    /** Inert documents, archives, audio and video get the larger managed-file budget. */
    fun isDeliveredFilePath(path: String) = isOutputPath(path) && extension(path) in deliveredExtensions

    private fun extension(path: String): String {
        val name = path.substringAfterLast('/')
        val dot = name.lastIndexOf('.')
        return if (dot <= 0) "" else name.substring(dot + 1).lowercase()
    }

    private fun isOutputPath(path: String) = path.startsWith("/") && utf8Length(path) <= 4_096 &&
        path.none { Character.isISOControl(it) || it.code in 0x202A..0x202E || it.code in 0x2066..0x2069 } &&
        "//" !in path && path.split('/').none { it == "." || it == ".." }
}

internal object HermesHttpDecoding {
    fun utf8(bytes: ByteArray): String = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    } catch (_: java.nio.charset.CharacterCodingException) {
        throw HermesException(HermesException.Kind.InvalidResponse)
    }

    fun json(bytes: ByteArray): JsonElement = try {
        StrictJson.parse(utf8(bytes))
    } catch (_: StrictJson.Malformed) {
        throw HermesException(HermesException.Kind.InvalidResponse)
    }
}
