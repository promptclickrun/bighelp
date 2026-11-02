package app.bighelp.hermes.chat

import app.bighelp.hermes.utf8Length
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

enum class CommandSource { Core, Plugin, Skill, User }

enum class ArgumentMode { None, Text, Options, Mixed }

/** One command from the host's `commands.catalog`. Its invocation identity is spelled exactly as the host named it. */
data class SlashCommand(
    val name: String,
    val description: String,
    val category: String,
    val aliases: List<String>,
    val argumentMode: ArgumentMode,
    val source: CommandSource,
)

/** A catalog command chosen for a typed message: which command, how it was invoked, and the rest of the text. */
data class SlashSelection(val command: SlashCommand, val invocation: String, val arguments: String)

/** The commands of one session or draft, and the strict mapping from typed text to a selection. */
class SlashCommandIndex(commands: List<SlashCommand>) {
    val commands: List<SlashCommand> = commands.distinctBy { it.name }

    /**
     * The command a draft names: a leading `/`, then a first token equal (case-insensitively) to a command name or
     * alias. Text after the first whitespace is the argument. Null when the token names nothing in this catalog.
     */
    fun selection(text: String): SlashSelection? {
        if (!text.startsWith("/")) return null
        val body = text.substring(1)
        val end = body.indexOfFirst { it.isWhitespace() }.let { if (it < 0) body.length else it }
        val token = body.substring(0, end).lowercase()
        if (token.isEmpty()) return null
        val command = commands.firstOrNull { it.name.lowercase() == token || it.aliases.any { alias -> alias.lowercase() == token } } ?: return null
        return SlashSelection(command, "/$token", body.substring(end).trimStart { it.isWhitespace() })
    }

    /** Commands to suggest while a draft is just a `/word` with no whitespace; none once it names a command. */
    fun suggestions(draft: String): List<SlashCommand> {
        if (!draft.startsWith("/") || draft.drop(1).any { it.isWhitespace() }) return emptyList()
        if (selection(draft) != null) return emptyList()
        val query = draft.drop(1).lowercase()
        if (query.isEmpty()) return commands
        return commands.filter { c -> c.name.lowercase().contains(query) || c.aliases.any { it.lowercase().contains(query) } || c.description.lowercase().contains(query) }
    }
}

internal object SlashCommandCatalog {
    const val MAXIMUM_PAIRS = 2_048
    const val MAXIMUM_DESCRIPTION = 240

    /** Skips an individual entry the app cannot show; the rest of the menu still loads. */
    fun decode(result: JsonElement): List<SlashCommand> {
        val body = result.asObject ?: throw invalidResponse()
        val pairs = body["pairs"].asArray ?: throw invalidResponse()
        if (pairs.size > MAXIMUM_PAIRS) throw invalidResponse()
        val categories = categoryByKey(body["categories"].asArray)
        val canonical = body["canon"].asObject ?: JsonObject(emptyMap())
        val metadata = body["commands"].asObject ?: JsonObject(emptyMap())
        val skills = body["skills"].asObject ?: JsonObject(emptyMap())
        return pairs.mapNotNull { pair ->
            val values = pair.asArray?.takeIf { it.size == 2 } ?: return@mapNotNull null
            val rawKey = values[0].asString ?: return@mapNotNull null
            val rawDescription = values[1].asString ?: return@mapNotNull null
            val name = commandName(rawKey) ?: return@mapNotNull null
            val isSkill = containsKey(skills, rawKey)
            val source = if (isSkill) CommandSource.Skill else when (categories[rawKey.lowercase()]?.lowercase()) {
                "plugin commands" -> CommandSource.Plugin
                "user commands" -> CommandSource.User
                else -> CommandSource.Core
            }
            SlashCommand(
                name = name, description = displayDescription(rawDescription),
                category = categories[rawKey.lowercase()] ?: if (source == CommandSource.Skill) "Skills" else "Commands",
                aliases = aliases(rawKey, canonical),
                argumentMode = metadataValue(metadata, rawKey)?.get("argument_mode").asString.let { mode -> ArgumentMode.entries.firstOrNull { it.name.lowercase() == mode } } ?: ArgumentMode.None,
                source = source,
            )
        }
    }

    /** Control characters become spaces and the text is trimmed to the composer's limit. */
    fun displayDescription(raw: String): String {
        val flat = raw.map { if (Character.getType(it) == Character.CONTROL.toInt()) ' ' else it }.joinToString("").trim { it == ' ' || it == '\t' }
        if (flat.isEmpty()) return "Command"
        if (flat.length <= MAXIMUM_DESCRIPTION) return flat
        return flat.take(MAXIMUM_DESCRIPTION - 1).trim { it == ' ' || it == '\t' } + "…"
    }

    private fun commandName(rawKey: String): String? {
        if (!rawKey.startsWith("/")) return null
        val name = rawKey.substring(1)
        if (name.isEmpty() || utf8Length(name) > 96) return null
        return name.takeIf { it.all { c -> Character.isLetterOrDigit(c) || c == '-' || c == '_' || c == '.' } }
    }

    private fun aliases(rawKey: String, canonical: JsonObject): List<String> {
        val result = ArrayList<String>()
        for ((aliasKey, value) in canonical) {
            if (aliasKey.lowercase() == rawKey.lowercase() || value.asString?.lowercase() != rawKey.lowercase()) continue
            val alias = commandName(aliasKey) ?: continue
            if (alias !in result) result += alias
        }
        return result.sorted().take(32)
    }

    private fun containsKey(obj: JsonObject, key: String) =
        obj.keys.any { it.lowercase() == key.lowercase() || it.lowercase() == key.drop(1).lowercase() }

    private fun metadataValue(obj: JsonObject, key: String): JsonObject? =
        obj.entries.firstOrNull { it.key.lowercase() == key.lowercase() || it.key.lowercase() == key.drop(1).lowercase() }?.value.asObject

    private fun categoryByKey(values: JsonArray?): Map<String, String> {
        val result = HashMap<String, String>()
        for (value in values.orEmpty()) {
            val obj = value.asObject ?: continue
            val category = obj["name"].asString?.takeIf { it.length in 1..80 && it.none { c -> Character.isISOControl(c) } } ?: continue
            for (pair in obj["pairs"].asArray.orEmpty()) {
                val fields = pair.asArray?.takeIf { it.size == 2 } ?: continue
                val key = fields[0].asString?.takeIf { it.startsWith("/") } ?: continue
                result[key.lowercase()] = category
            }
        }
        return result
    }

    /** Splits typed text the way Hermes' `slash.exec` does: the name after the slashes (lowercased), then the rest. */
    fun typedDispatch(message: String): Pair<String, String> {
        val command = message.trim().trimStart('/')
        val name = command.takeWhile { !it.isWhitespace() }
        val arg = command.drop(name.length).trimStart { it.isWhitespace() }
        return name.lowercase() to arg
    }
}
