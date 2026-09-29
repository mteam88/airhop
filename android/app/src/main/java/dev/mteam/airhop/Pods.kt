package dev.mteam.airhop

import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

/** What the AirPods say about themselves in their BLE proximity advertisement. */
data class PodState(
    val leftInEar: Boolean,
    val rightInEar: Boolean,
    val conn: Int,
    /** Last three bytes of the BT address currently holding the AirPods, e.g. "". */
    val holder: String,
    val leftBattery: Int?,
    val rightBattery: Int?,
    val seenAt: Long,
) {
    val worn get() = leftInEar || rightInEar
    val disconnected get() = conn == CONN_DISCONNECTED

    override fun toString() =
        "worn=${ear()} conn=${connName()} holder=$holder batt=${leftBattery ?: "?"}/${rightBattery ?: "?"}"

    private fun ear() = when {
        leftInEar && rightInEar -> "LR"
        leftInEar -> "L"
        rightInEar -> "R"
        else -> "-"
    }

    private fun connName() = when (conn) {
        CONN_DISCONNECTED -> "disconnected"
        0x04 -> "idle"
        0x05 -> "music"
        0x06 -> "call"
        0x07 -> "ringing"
        0x09 -> "hanging-up"
        else -> "0x%02x".format(conn)
    }

    companion object {
        const val CONN_DISCONNECTED = 0x00
    }
}

class PodKeys(val irk: ByteArray, val enc: ByteArray) {
    fun toPrefs() = irk.hex() + ":" + enc.hex()

    companion object {
        fun fromPrefs(s: String?): PodKeys? =
            s?.split(":")?.takeIf { it.size == 2 }?.let { PodKeys(it[0].unhex(), it[1].unhex()) }

        /** Parses an AACP proximity-keys response: 04 00 04 00 31 00 <count> {type 00 len 00 key}... */
        fun fromAacp(packet: ByteArray): PodKeys? {
            if (packet.size < 7 || packet[4] != 0x31.toByte()) return null
            var irk: ByteArray? = null
            var enc: ByteArray? = null
            var offset = 7
            repeat(packet[6].toInt()) {
                if (offset + 4 > packet.size) return@repeat
                val type = packet[offset].toInt()
                val len = packet[offset + 2].toInt()
                val key = packet.copyOfRange(offset + 4, offset + 4 + len)
                if (type == 0x01) irk = key
                if (type == 0x04) enc = key
                offset += 4 + len
            }
            return if (irk != null && enc != null) PodKeys(irk!!, enc!!) else null
        }
    }
}

object Pods {
    /**
     * Parses Apple manufacturer data (company id stripped): 07 19 <prefix> <model:2> <status>
     * <battery> <flags> <lid> <color> <conn> ... <16 encrypted bytes>.
     */
    fun parse(data: ByteArray, keys: PodKeys, now: Long): PodState? {
        if (data.size < 27 || data[0] != 0x07.toByte()) return null
        val plain = aes(Cipher.DECRYPT_MODE, keys.enc, data.copyOfRange(data.size - 16, data.size))
        val status = data[5].toInt() and 0xff
        val primaryLeft = (status shr 5) and 1 == 1
        val thisInCase = (status shr 6) and 1 == 1
        val flipped = primaryLeft xor thisInCase
        val a = status and 0x02 != 0
        val b = status and 0x08 != 0
        return PodState(
            leftInEar = if (flipped) b else a,
            rightInEar = if (flipped) a else b,
            conn = data[10].toInt() and 0xff,
            holder = plain.copyOfRange(4, 7).hex(),
            leftBattery = battery(plain[if (primaryLeft) 1 else 2]),
            rightBattery = battery(plain[if (primaryLeft) 2 else 1]),
            seenAt = now,
        )
    }

    /** Resolvable private address check per the BT core spec's ah() function. */
    fun addressMatches(address: String, irk: ByteArray): Boolean {
        val a = address.replace(":", "").unhex()
        val r = ByteArray(16).also { a.copyInto(it, destinationOffset = 13, startIndex = 0, endIndex = 3) }
        // The spec's AES is MSB-first; the IRK arrives LSB-first.
        val hash = aes(Cipher.ENCRYPT_MODE, irk.reversedArray(), r)
        return hash[13] == a[3] && hash[14] == a[4] && hash[15] == a[5]
    }

    private fun battery(b: Byte): Int? = (b.toInt() and 0xff).takeIf { it != 0xff }?.and(0x7f)

    private fun aes(mode: Int, key: ByteArray, block: ByteArray): ByteArray =
        Cipher.getInstance("AES/ECB/NoPadding").run {
            init(mode, SecretKeySpec(key, "AES"))
            doFinal(block)
        }
}

fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

fun String.unhex() = ByteArray(length / 2) { substring(2 * it, 2 * it + 2).toInt(16).toByte() }
