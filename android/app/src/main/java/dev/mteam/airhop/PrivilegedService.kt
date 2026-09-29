package dev.mteam.airhop

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.os.IBinder
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import kotlin.system.exitProcess

/**
 * Shizuku user service. Lives in a separate process running as the shell uid, which on the
 * Pixel holds BLUETOOTH_PRIVILEGED — enough to force A2DP/HFP connections without root.
 */
class PrivilegedService : IPrivileged.Stub() {
    private val adapter = shellAdapter()

    override fun destroy(): Unit = exitProcess(0)

    override fun connect(address: String) = callStatus(device(address), "connect")

    override fun disconnect(address: String) = callStatus(device(address), "disconnect")

    override fun setActive(address: String): Boolean =
        adapter.javaClass
            .getMethod("setActiveDevice", BluetoothDevice::class.java, Int::class.javaPrimitiveType)
            .invoke(adapter, device(address), ACTIVE_DEVICE_ALL) as Boolean

    override fun selfAddress(): String = adapter.address

    override fun fetchProximityKeys(address: String): ByteArray? {
        val ctor = BluetoothSocket::class.java.declaredConstructors.first {
            it.parameterTypes.size == 7 && it.parameterTypes[0] == BluetoothAdapter::class.java
        }.apply { isAccessible = true }
        val socket = ctor.newInstance(
            adapter, device(address), L2CAP, true, true, AACP_PSM, ParcelUuid.fromString(AACP_UUID)
        ) as BluetoothSocket
        // Reads block; bound the whole exchange.
        val watchdog = Thread { runCatching { Thread.sleep(10_000); socket.close() } }
        watchdog.isDaemon = true
        watchdog.start()
        return try {
            socket.connect()
            val out = socket.outputStream
            out.write(HANDSHAKE)
            Thread.sleep(300)
            out.write(SET_FEATURE_FLAGS)
            Thread.sleep(200)
            out.write(REQUEST_KEYS)
            val buf = ByteArray(1024)
            var n = socket.inputStream.read(buf)
            while (n > 0) {
                if (n > 4 && buf[4] == 0x31.toByte()) return buf.copyOf(n)
                n = socket.inputStream.read(buf)
            }
            null
        } catch (e: Exception) {
            Log.w(TAG, "key fetch failed", e)
            null
        } finally {
            runCatching { socket.close() }
        }
    }

    private fun device(address: String) = adapter.getRemoteDevice(address)

    private fun callStatus(device: BluetoothDevice, method: String): Boolean =
        device.javaClass.getMethod(method).invoke(device) as Int == STATUS_SUCCESS

    /** Context that attributes Bluetooth calls to the shell package, matching our uid. */
    private class ShellContext(base: Context) : ContextWrapper(base) {
        override fun getPackageName() = SHELL
        override fun getOpPackageName() = SHELL
        override fun getAttributionSource(): AttributionSource =
            AttributionSource.Builder(android.os.Process.myUid()).setPackageName(SHELL).build()
        override fun getApplicationContext() = this
    }

    private companion object {
        const val TAG = "airhop.priv"
        const val SHELL = "com.android.shell"
        const val ACTIVE_DEVICE_ALL = 2
        const val STATUS_SUCCESS = 0
        const val L2CAP = 3
        const val AACP_PSM = 0x1001
        const val AACP_UUID = "74ec2172-0bad-4d01-8f77-997b2be0722a"
        val HANDSHAKE = byteArrayOf(0, 0, 4, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        val SET_FEATURE_FLAGS = byteArrayOf(4, 0, 4, 0, 0x4d, 0, 0xd7.toByte(), 0, 0, 0, 0, 0, 0, 0)
        val REQUEST_KEYS = byteArrayOf(4, 0, 4, 0, 0x30, 0, 0x05, 0) // IRK | ENC_KEY

        /**
         * app_process has no application context and Bluetooth's framework initializer never ran,
         * so wire up the adapter by hand from the raw bluetooth_manager binder.
         */
        fun shellAdapter(): BluetoothAdapter {
            val context = ShellContext(systemContext())
            val bsm = Class.forName("android.os.BluetoothServiceManager")
            Class.forName("android.bluetooth.BluetoothFrameworkInitializer")
                .getMethod("setBluetoothServiceManager", bsm)
                .invoke(null, bsm.getDeclaredConstructor().apply { isAccessible = true }.newInstance())
            val binder = Class.forName("android.os.ServiceManager")
                .getMethod("getService", String::class.java).invoke(null, "bluetooth_manager") as IBinder
            val managerClass = Class.forName("android.bluetooth.IBluetoothManager")
            val manager = Class.forName("android.bluetooth.IBluetoothManager\$Stub")
                .getMethod("asInterface", IBinder::class.java).invoke(null, binder)
            return BluetoothAdapter::class.java
                .getDeclaredConstructor(managerClass, Context::class.java, AttributionSource::class.java)
                .apply { isAccessible = true }
                .newInstance(manager, context, context.attributionSource)
        }

        fun systemContext(): Context {
            if (Looper.getMainLooper() == null) Looper.prepareMainLooper()
            val at = Class.forName("android.app.ActivityThread")
            val thread = at.getMethod("currentActivityThread").invoke(null)
                ?: at.getDeclaredConstructor().apply { isAccessible = true }.newInstance().also {
                    at.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }.set(null, it)
                    at.getDeclaredField("mSystemThread").apply { isAccessible = true }.setBoolean(it, true)
                }
            return at.getDeclaredMethod("getSystemContext").invoke(thread) as Context
        }
    }
}
