package dev.mteam.airhop

import android.os.ParcelUuid
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

/**
 * Mac <-> Pixel side channel: a legacy BLE advertisement carrying one 128-bit service UUID.
 * UUIDs derive from the AirPods' advertisement key so they aren't guessable from this source.
 */
object Beacon {
    fun uuid(sender: String, kind: String, keys: PodKeys): ParcelUuid {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("airhop/v1/$sender/$kind/${keys.enc.hex()}".toByteArray())
        val buf = ByteBuffer.wrap(digest, 0, 16)
        return ParcelUuid(UUID(buf.long, buf.long))
    }
}
