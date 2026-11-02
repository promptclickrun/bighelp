package app.bighelp.hermes

/**
 * Literal IP syntax only. Nothing here touches `java.net.InetAddress`, so no host name is ever resolved
 * and DNS can never decide whether plain HTTP is allowed.
 */
internal object HermesAddress {
    /** Strict dotted-decimal: four parts, 0–255, no leading zeros. `127.1`, `0x7f.0.0.1` and integers fail. */
    fun parseIPv4(text: String): ByteArray? {
        val parts = text.split('.')
        if (parts.size != 4) return null
        val bytes = ByteArray(4)
        for ((index, part) in parts.withIndex()) {
            if (part.isEmpty() || part.length > 3 || !part.all { it in '0'..'9' }) return null
            if (part.length > 1 && part[0] == '0') return null
            val value = part.toInt()
            if (value > 255) return null
            bytes[index] = value.toByte()
        }
        return bytes
    }

    /** RFC 4291 text forms with `::` and a trailing dotted quad. No zone ID, no brackets. */
    fun parseIPv6(text: String): ByteArray? {
        if (text.isEmpty() || !text.all { it == ':' || it == '.' || Character.digit(it, 16) >= 0 && it.code < 0x80 }) {
            return null
        }
        val gap = text.indexOf("::")
        if (gap >= 0 && text.indexOf("::", gap + 1) >= 0) return null
        val head = if (gap >= 0) text.substring(0, gap) else text
        val tail = if (gap >= 0) text.substring(gap + 2) else ""
        // The dotted quad may only close the address: the tail when there is a "::", else the whole text.
        val headWords = words(head, allowIPv4 = gap < 0) ?: return null
        val tailWords = words(tail, allowIPv4 = gap >= 0) ?: return null
        val total = headWords.size + tailWords.size
        if (gap >= 0) { if (total > 7) return null } else if (total != 8) return null
        val all = headWords + List(8 - total) { 0 } + tailWords
        return ByteArray(16) { (all[it / 2] shr (if (it % 2 == 0) 8 else 0)).toByte() }
    }

    private fun words(part: String, allowIPv4: Boolean): List<Int>? {
        if (part.isEmpty()) return emptyList()
        val pieces = part.split(':')
        val result = ArrayList<Int>()
        for ((index, piece) in pieces.withIndex()) {
            if ('.' in piece) {
                if (!allowIPv4 || index != pieces.lastIndex) return null
                val quad = parseIPv4(piece) ?: return null
                result += ((quad[0].toInt() and 0xff) shl 8) or (quad[1].toInt() and 0xff)
                result += ((quad[2].toInt() and 0xff) shl 8) or (quad[3].toInt() and 0xff)
            } else {
                if (piece.isEmpty() || piece.length > 4) return null
                result += piece.toInt(16)
            }
        }
        return result
    }

    /** Names that only resolve inside a private network; a Tailscale Funnel name is public only over HTTPS. */
    private val privateNameSuffixes = listOf(
        "local", "lan", "internal", "home.arpa", "intranet", "corp", "localdomain", "private",
        "localhost", "ts.net", "beta.tailscale.net",
    )

    /**
     * Plain HTTP stays on a network the person controls: this device, home or office Wi-Fi, a VPN or
     * Tailscale. IPv4-mapped and link-local IPv6 forms are deliberately not included.
     */
    fun isPrivateNetworkHost(host: String): Boolean {
        val name = host.lowercase()
        parseIPv4(name)?.let { return isPrivateIPv4(it) }
        parseIPv6(name)?.let { return isLoopbackOrUniqueLocalIPv6(it) }
        // A single-label name ("hermes") never leaves the local resolver.
        if ('.' !in name) return true
        return privateNameSuffixes.any { name.endsWith(".$it") }
    }

    private fun isPrivateIPv4(address: ByteArray): Boolean {
        val a = address[0].toInt() and 0xff
        val b = address[1].toInt() and 0xff
        return a == 127 ||                              // loopback
            a == 10 ||                                  // 10.0.0.0/8
            (a == 172 && b in 16..31) ||                // 172.16.0.0/12
            (a == 192 && b == 168) ||                   // 192.168.0.0/16
            (a == 100 && b in 64..127) ||               // 100.64.0.0/10 (Tailscale, CGNAT)
            (a == 169 && b == 254)                      // link-local
    }

    private fun isLoopbackOrUniqueLocalIPv6(address: ByteArray): Boolean {
        val loopback = address.take(15).all { it.toInt() == 0 } && address[15].toInt() == 1
        // fc00::/7 unique local, which includes Tailscale's fd7a:115c:a1e0::/48.
        return loopback || (address[0].toInt() and 0xfe) == 0xfc
    }
}
