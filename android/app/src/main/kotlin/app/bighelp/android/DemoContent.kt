package app.bighelp.android

/**
 * The sample conversations behind "Try the demo". Everything here is invented; no person, host or plan is
 * real. Replies are fixed text written by the app, never by an agent, and appear at once.
 */
object DemoContent {
    private val scout = DemoAgent("scout", "Scout", "Looks things up and sums them up", 0xFF2F6FD6)
    private val ledger = DemoAgent("ledger", "Ledger", "Keeps lists, plans and errands", 0xFF1F7A4D)
    private val tinker = DemoAgent("tinker", "Tinker", "Helps with code and small fixes", 0xFF8250DF)

    /** Used for every demo reply, so what is sample data is never in doubt. */
    fun exampleReply(agent: DemoAgent): String =
        "This is an example reply. ${agent.name} is a sample agent in the demo, so this answer is fixed " +
            "text. Your message stayed on this phone."

    fun initial(): DemoState = DemoState(
        agents = listOf(scout, ledger, tinker),
        selectedAgentId = scout.id,
        sessions = listOf(lakeWeekend(), router(), dateTest()),
    )

    private fun lakeWeekend(): DemoSession {
        val items = listOf(
            "tent" to "the two-person one is on the garage shelf",
            "sleeping bags" to "check the zips before you leave",
            "headlamps" to "pack spare batteries",
            "water filter" to "rinse it the night before",
            "camp stove" to "fuel is a separate item",
            "first-aid kit" to "restock the plasters",
            "sunscreen" to "SPF 50 for the water",
            "rain jackets" to "the forecast is mixed",
            "folding chairs" to "two is enough",
            "cooler" to "fill it last",
            "playing cards" to "for the evening",
            "bug spray" to "dusk is the worst",
            "trash bags" to "pack out what you pack in",
            "phone chargers" to "bring a power bank too",
            "swim towels" to "quick-dry ones",
            "marshmallows" to "obviously",
        )
        val messages = buildList {
            add("Can you help me plan packing for the lake weekend?" to true)
            add("Happy to. Tell me one thing at a time and I'll keep the list." to false)
            items.forEach { (item, note) ->
                add("What about the $item?" to true)
                add("Add the $item: $note." to false)
            }
        }
        return DemoSession(
            id = "lake",
            agentId = ledger.id,
            title = "Lake weekend packing",
            messages = messages.mapIndexed { index, (text, fromUser) -> DemoMessage("lake/$index", fromUser, text) },
        )
    }

    private fun router(): DemoSession = DemoSession(
        id = "router",
        agentId = scout.id,
        title = "Which router should I buy?",
        messages = listOf(
            DemoMessage("router/0", true, "Which router should I buy for a small flat?"),
            DemoMessage(
                "router/1", false,
                "For a small flat a single mid-range Wi-Fi 6 router is plenty. Mesh kits only pay off " +
                    "when walls or floors block the signal.",
            ),
            DemoMessage("router/2", true, "Is it worth paying for Wi-Fi 7?"),
            DemoMessage(
                "router/3", false,
                "Only if your devices support it. Most still don't, so Wi-Fi 6 is the safer buy today.",
            ),
        ),
    )

    private fun dateTest(): DemoSession = DemoSession(
        id = "date-test",
        agentId = tinker.id,
        title = "Fix the failing date test",
        messages = listOf(
            DemoMessage("date-test/0", true, "The date test fails only on the last day of the month."),
            DemoMessage(
                "date-test/1", false,
                "That points to adding days to a date and then reading the month. Try building the " +
                    "expected value from the same starting date instead of today's.",
            ),
        ),
    )
}
