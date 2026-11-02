package app.bighelp.hermes

/** Byte-exact validation of tokens and identities. Nothing is trimmed, normalized or case-folded. */
object HermesSecrets {
    const val MAXIMUM_TOKEN_BYTES = 16_384
    const val MAXIMUM_PROVIDER_BYTES = 128
    const val MAXIMUM_USER_ID_BYTES = 512

    /** Session, access and refresh tokens: 1 to 16,384 bytes of printable ASCII (U+0021–U+007E). */
    fun isValidToken(value: String): Boolean =
        value.isNotEmpty() && value.length <= MAXIMUM_TOKEN_BYTES && value.all { it.code in 0x21..0x7e }

    /** @throws HermesException [HermesException.Kind.InvalidCredentials] for anything [isValidToken] refuses. */
    fun requireToken(value: String) {
        if (!isValidToken(value)) throw HermesException(HermesException.Kind.InvalidCredentials)
    }

    /**
     * A provider or user ID: nonempty, within [maximumBytes] of UTF-8, no leading or trailing Unicode
     * whitespace, and no ASCII control or DEL.
     */
    fun isValidIdentity(value: String, maximumBytes: Int): Boolean =
        value.isNotEmpty() && utf8Length(value) <= maximumBytes &&
            !Character.isWhitespace(value.first()) && !Character.isSpaceChar(value.first()) &&
            !Character.isWhitespace(value.last()) && !Character.isSpaceChar(value.last()) &&
            value.none { it.code < 0x20 || it.code == 0x7f }
}
