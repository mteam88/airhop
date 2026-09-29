package dev.mteam.airhop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.ParcelUuid
import android.os.SystemClock
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import android.view.KeyEvent
import rikka.shizuku.Shizuku
import java.io.FileDescriptor
import java.io.PrintWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Keeps the AirPods following whatever this phone is doing:
 *  - local media or a call starts while they're worn elsewhere -> pause, grab them, resume;
 *  - they're worn and connected to nothing (e.g. the Mac went to sleep) -> grab them;
 *  - another device takes them while we're playing -> pause instead of blasting the speaker.
 * Every decision is driven by the AirPods' own BLE advertisement, which carries in-ear state,
 * connection state and the address of whoever currently holds them.
 */
class HopService : Service() {
    private val thread = HandlerThread("airhop").apply { start() }
    private val handler = Handler(thread.looper)
    private val events = ArrayDeque<String>()
    private val prefs by lazy { getSharedPreferences("airhop", MODE_PRIVATE) }
    private val audio by lazy { getSystemService(AudioManager::class.java) }
    private val adapter by lazy { getSystemService(BluetoothManager::class.java).adapter }

    private var a2dp: BluetoothA2dp? = null
    private var priv: IPrivileged? = null
    private var keys: PodKeys? = null
    private var pods: PodState? = null
    private var selfSuffix: String? = null
    private var scanning = false
    private val verified = HashSet<String>()
    private val rejected = HashSet<String>()

    private var mediaActive = false
    private var voipActive = false
    private var busyUntil = 0L
    private var lastIdleGrab = 0L
    /** Don't idle-grab while the Mac is mid-connect after asking for the AirPods. */
    private var idleSuppressedUntil = 0L
    private var idleSince = 0L
    private var lostSince = 0L
    private var lastBeaconAt = 0L
    /** Set once the advertisement confirms we hold the AirPods; its holder field lags ~6s. */
    private var ownedConfirmed = false

    private val startedAt = SystemClock.elapsedRealtime()

    private val airpods get() = prefs.getString(PREF_AIRPODS, null)

    override fun onCreate() {
        super.onCreate()
        instance = this
        startForeground(1, notification("starting"), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        keys = PodKeys.fromPrefs(prefs.getString(PREF_KEYS, null))
        adapter.getProfileProxy(this, object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                a2dp = proxy as BluetoothA2dp
                handler.post { if (airpods == null) adoptConnectedAirPods() }
            }

            override fun onServiceDisconnected(profile: Int) {
                a2dp = null
            }
        }, BluetoothProfile.A2DP)
        audio.registerAudioPlaybackCallback(playbackCallback, handler)
        audio.addOnModeChangedListener({ handler.post(it) }, modeListener)
        if (checkSelfPermission(android.Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED) {
            getSystemService(TelephonyManager::class.java)
                .registerTelephonyCallback({ handler.post(it) }, callCallback)
        }
        Shizuku.addBinderReceivedListenerSticky(onShizukuBinder)
        Shizuku.addBinderDeadListener(onShizukuDead)
        handler.post { startScan() }
        handler.postDelayed(::checkMedia, 3_000) // once Shizuku and the A2DP proxy are up
        handler.postDelayed({ updateNotification() }, SHIZUKU_GRACE_MS + 100)
        handler.postDelayed(shizukuWatchdog, 10_000)
        log("started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.let { i -> handler.post { command(i) } }
        return START_STICKY
    }

    override fun onDestroy() {
        instance = null
        Shizuku.removeBinderReceivedListener(onShizukuBinder)
        Shizuku.removeBinderDeadListener(onShizukuDead)
        audio.unregisterAudioPlaybackCallback(playbackCallback)
        audio.removeOnModeChangedListener(modeListener)
        runCatching { getSystemService(TelephonyManager::class.java).unregisterTelephonyCallback(callCallback) }
        if (scanning) adapter.bluetoothLeScanner?.stopScan(scanCallback)
        thread.quitSafely()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** `adb shell am start-foreground-service -n dev.mteam.airhop/.HopService -a <action> ...` */
    private fun command(intent: Intent) {
        when (intent.action) {
            "set" -> {
                intent.getStringExtra("airpods")?.let { prefs.edit().putString(PREF_AIRPODS, it.uppercase()).apply() }
                intent.getStringExtra("keys")?.let {
                    keys = PodKeys.fromPrefs(it)
                    prefs.edit().putString(PREF_KEYS, it).apply()
                    verified.clear(); rejected.clear()
                    startScan()
                }
                log("config updated: airpods=$airpods keys=${keys != null}")
            }
            "take" -> take("manual", pauseMedia = false)
            "release" -> priv?.disconnect(airpods ?: return)
            "advertise" -> advertise(intent.getStringExtra("kind") ?: "take")
            "beacons" -> keys?.let { k ->
                listOf("mac", "pixel").forEach { who ->
                    listOf("take", "release").forEach { kind -> log("beacon $who/$kind = ${Beacon.uuid(who, kind, k)}") }
                }
            }
        }
    }

    // --- Shizuku ---------------------------------------------------------------------------

    private val onShizukuBinder = Shizuku.OnBinderReceivedListener { handler.post { bindPrivileged() } }

    private var lastBindAttempt = 0L

    /** Idempotent; also driven by [shizukuWatchdog] since Shizuku may come up (or get permission) after us. */
    private fun bindPrivileged() {
        if (priv != null || !Shizuku.pingBinder()) return
        if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
            return log("shizuku running but airhop isn't allowed; open airhop to grant it")
        }
        val now = SystemClock.elapsedRealtime()
        if (now - lastBindAttempt < 20_000) return
        lastBindAttempt = now
        log("binding privileged service")
        val args = Shizuku.UserServiceArgs(ComponentName(packageName, PrivilegedService::class.java.name))
            .daemon(false)
            .processNameSuffix("priv")
            .version(packageManager.getPackageInfo(packageName, 0).longVersionCode.toInt())
        runCatching { Shizuku.bindUserService(args, privConnection) }
            .onFailure { log("shizuku bind failed: $it") }
    }

    private val shizukuWatchdog = object : Runnable {
        override fun run() {
            bindPrivileged()
            handler.postDelayed(this, 10_000)
        }
    }

    private val onShizukuDead = Shizuku.OnBinderDeadListener {
        priv = null
        lastBindAttempt = 0L
        log("shizuku died; can't connect until it's restarted")
        updateNotification()
    }

    private val privConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val service = IPrivileged.Stub.asInterface(binder)
            handler.post {
                priv = service
                selfSuffix = service.selfAddress().replace(":", "").takeLast(6).lowercase()
                log("privileged service ready (self=$selfSuffix)")
                updateNotification()
                if (keys == null) fetchKeys()
            }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            handler.post {
                priv = null
                log("privileged service disconnected")
                updateNotification()
            }
        }
    }

    /** First run: pick up whichever AirPods are connected right now. */
    private fun adoptConnectedAirPods() {
        val device = a2dp?.connectedDevices?.firstOrNull { d ->
            d.uuids?.any { it == ParcelUuid.fromString(AACP_UUID) } == true
        } ?: return
        prefs.edit().putString(PREF_AIRPODS, device.address).apply()
        log("adopted AirPods ${device.address}")
        if (keys == null) fetchKeys()
    }

    private fun fetchKeys() {
        val priv = priv ?: return
        val address = airpods ?: return
        if (!connectedHere()) return log("need AirPods connected to fetch their keys")
        val fetched = priv.fetchProximityKeys(address)?.let(PodKeys::fromAacp)
            ?: return log("key fetch failed")
        keys = fetched
        prefs.edit().putString(PREF_KEYS, fetched.toPrefs()).apply()
        log("fetched AirPods proximity keys")
        startScan()
    }

    // --- BLE -------------------------------------------------------------------------------

    private fun startScan() {
        if (scanning || keys == null) return
        val scanner = adapter.bluetoothLeScanner ?: return
        val keys = keys!!
        val pods = ScanFilter.Builder()
            .setManufacturerData(APPLE, byteArrayOf(0x07), byteArrayOf(0xff.toByte()))
            .build()
        val beacons = listOf("take", "release").map { kind ->
            ScanFilter.Builder().setServiceUuid(Beacon.uuid("mac", kind, keys)).build()
        }
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(pods) + beacons, settings, scanCallback)
        scanning = true
        log("scanning for AirPods broadcasts")
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val record = result.scanRecord ?: return
            val uuids = record.serviceUuids
            if (!uuids.isNullOrEmpty()) {
                handler.post { onBeacon(uuids) }
                return
            }
            val data = record.getManufacturerSpecificData(APPLE) ?: return
            handler.post { onAdvert(result.device.address, data) }
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            log("BLE scan failed: $errorCode")
        }
    }

    private fun onAdvert(address: String, data: ByteArray) {
        val keys = keys ?: return
        if (address in rejected) return
        if (address !in verified) {
            if (!Pods.addressMatches(address, keys.irk)) {
                if (rejected.size > 500) rejected.clear()
                rejected += address
                return
            }
            verified += address
        }
        val state = Pods.parse(data, keys, SystemClock.elapsedRealtime()) ?: return
        val changed = pods?.toString() != state.toString()
        pods = state
        if (state.holder == selfSuffix && connectedHere()) ownedConfirmed = true
        if (changed) {
            log("airpods $state")
            updateNotification()
        }
        evaluate(state)
    }

    // --- Rules -----------------------------------------------------------------------------

    private fun evaluate(p: PodState) {
        val now = SystemClock.elapsedRealtime()
        if (now < busyUntil) return
        val here = connectedHere()

        // Worn and connected to nothing: the phone is home base.
        if (p.worn && p.disconnected && !here && now >= idleSuppressedUntil) {
            if (idleSince == 0L) idleSince = now
            if (now - idleSince >= IDLE_GRACE_MS && now - lastIdleGrab >= IDLE_RETRY_MS) {
                lastIdleGrab = now
                take("worn and idle", pauseMedia = false)
            }
        } else {
            idleSince = 0L
        }

        // Another device took them while we're playing; Android only notices ~5s later.
        if (lostToOther(p)) {
            if (lostSince == 0L) lostSince = now
            if (now - lostSince >= LOST_GRACE_MS && mediaActive) {
                log("taken by ${p.holder}; pausing")
                mediaKey(KeyEvent.KEYCODE_MEDIA_PAUSE)
                lostSince = Long.MAX_VALUE
            }
        } else {
            lostSince = 0L
        }
    }

    private fun onLocalIntent(reason: String, pauseMedia: Boolean) {
        if (SystemClock.elapsedRealtime() < busyUntil) return
        val p = pods
        if (connectedHere() && (p == null || !lostToOther(p))) return
        if (p == null || !fresh(p) || !p.worn) return log("$reason, but AirPods aren't worn nearby")
        take(reason, pauseMedia)
    }

    private fun take(reason: String, pauseMedia: Boolean) {
        val priv = priv ?: return log("$reason: can't connect, Shizuku isn't running")
        val address = airpods ?: return log("$reason: no AirPods configured")
        val start = SystemClock.elapsedRealtime()
        busyUntil = start + 15_000
        log("$reason -> taking AirPods")
        ownedConfirmed = false
        if (pauseMedia) mediaKey(KeyEvent.KEYCODE_MEDIA_PAUSE)
        // Tell the Mac so it pauses and lets go instead of us wrestling it for the link.
        if (pods?.disconnected != true) {
            advertise("take")
            Thread.sleep(250)
        }
        if (connectedHere()) {
            // Our link is stale: someone else holds them but Android hasn't noticed yet.
            priv.disconnect(address)
            waitFor(3_000) { !connectedHere() }
        }
        priv.connect(address)
        val ok = waitFor(8_000) { connectedHere() }
        if (ok) runCatching { priv.setActive(address) }
        log(if (ok) "connected in ${SystemClock.elapsedRealtime() - start}ms" else "connect timed out")
        if (pauseMedia) {
            Thread.sleep(400)
            mediaKey(KeyEvent.KEYCODE_MEDIA_PLAY)
            // AirPods sometimes pause the stream right after connecting.
            handler.postDelayed({ if (!audio.isMusicActive) mediaKey(KeyEvent.KEYCODE_MEDIA_PLAY) }, 1_500)
        }
        busyUntil = SystemClock.elapsedRealtime() + SETTLE_MS
    }

    private fun lostToOther(p: PodState) =
        ownedConfirmed && connectedHere() && !p.disconnected && p.holder != selfSuffix

    private fun onBeacon(uuids: List<ParcelUuid>) {
        val keys = keys ?: return
        val now = SystemClock.elapsedRealtime()
        if (now - lastBeaconAt < BEACON_DEDUPE_MS) return
        when {
            Beacon.uuid("mac", "take", keys) in uuids -> {
                lastBeaconAt = now
                if (!connectedHere()) return
                log("mac is taking the AirPods; pausing and letting go")
                idleSuppressedUntil = now + 8_000
                if (mediaActive) mediaKey(KeyEvent.KEYCODE_MEDIA_PAUSE)
                priv?.disconnect(airpods ?: return)
            }
            Beacon.uuid("mac", "release", keys) in uuids -> {
                lastBeaconAt = now
                val p = pods
                if (connectedHere() || p == null || !fresh(p) || !p.worn) return
                busyUntil = 0L
                take("mac released them", pauseMedia = false)
            }
        }
    }

    private fun advertise(kind: String) {
        val keys = keys ?: return
        val advertiser = adapter.bluetoothLeAdvertiser ?: return
        val params = AdvertisingSetParameters.Builder()
            .setLegacyMode(true)
            .setConnectable(false)
            .setScannable(false)
            .setInterval(AdvertisingSetParameters.INTERVAL_MIN)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
            .build()
        val data = AdvertiseData.Builder().addServiceUuid(Beacon.uuid("pixel", kind, keys)).build()
        // One callback per beacon: the stack ties a set to its callback, and reusing one tears the old set down.
        val callback = object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
                if (status != ADVERTISE_SUCCESS) log("beacon $kind failed: $status")
            }
        }
        advertiser.startAdvertisingSet(params, data, null, null, null, callback)
        handler.postDelayed({ advertiser.stopAdvertisingSet(callback) }, BEACON_MS)
        log("beacon $kind")
    }

    // Player configs include paused/idle players and apps can't see their state, so ask the mixer.
    // The callback fires as a player starts, a beat before the mixer reports it active: re-check.
    private val playbackCallback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<android.media.AudioPlaybackConfiguration>) {
            checkMedia()
            handler.postDelayed(::checkMedia, 300)
            handler.postDelayed(::checkMedia, 1_000)
        }
    }

    private fun checkMedia() {
        val media = audio.isMusicActive
        if (media && !mediaActive) onLocalIntent("media started", pauseMedia = true)
        mediaActive = media
    }

    private val modeListener = AudioManager.OnModeChangedListener { mode ->
        val voip = mode == AudioManager.MODE_IN_COMMUNICATION
        if (voip && !voipActive) onLocalIntent("voice call started", pauseMedia = false)
        voipActive = voip
    }

    private val callCallback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
        override fun onCallStateChanged(state: Int) {
            if (state != TelephonyManager.CALL_STATE_IDLE) onLocalIntent("phone call", pauseMedia = false)
        }
    }

    // --- Helpers ---------------------------------------------------------------------------

    private fun connectedHere(): Boolean {
        val address = airpods ?: return false
        val a2dp = a2dp ?: return false
        return a2dp.getConnectionState(adapter.getRemoteDevice(address)) == BluetoothProfile.STATE_CONNECTED
    }

    private fun fresh(p: PodState) = SystemClock.elapsedRealtime() - p.seenAt < STALE_MS

    private fun waitFor(timeoutMs: Long, condition: () -> Boolean): Boolean {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition()) return true
            Thread.sleep(100)
        }
        return condition()
    }

    private fun mediaKey(code: Int) {
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
    }

    private fun log(message: String) {
        Log.i(TAG, message)
        val line = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date()) + " " + message
        synchronized(events) {
            events.addLast(line)
            while (events.size > 200) events.removeFirst()
        }
    }

    fun status(): String {
        val shizuku = when {
            priv != null -> "ready"
            !Shizuku.pingBinder() -> "not running — start it from the Shizuku app"
            Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED -> "permission needed"
            else -> "binding…"
        }
        val lines = synchronized(events) { events.toList().takeLast(40).reversed() }
        return buildString {
            appendLine("Shizuku: $shizuku")
            appendLine("AirPods: ${airpods ?: "none yet (connect them once)"}")
            appendLine("Keys: ${if (keys != null) "ok" else "missing"}   here: ${connectedHere()}")
            appendLine("State: ${pods?.let { "$it (${(SystemClock.elapsedRealtime() - it.seenAt) / 1000}s ago)" } ?: "not seen"}")
            appendLine()
            lines.forEach { appendLine(it) }
        }
    }

    override fun dump(fd: FileDescriptor?, writer: PrintWriter, args: Array<out String>?) {
        writer.print(status())
    }

    private fun notification(text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("status", "Status", NotificationManager.IMPORTANCE_MIN))
        nm.createNotificationChannel(NotificationChannel("alert", "Needs attention", NotificationManager.IMPORTANCE_DEFAULT))
        // Shizuku dies on reboot and can only restart itself on rooted phones; nag until it's back.
        val needsShizuku = priv == null && SystemClock.elapsedRealtime() - startedAt > SHIZUKU_GRACE_MS
        val builder = Notification.Builder(this, if (needsShizuku) "alert" else "status")
            .setSmallIcon(R.drawable.ic_airhop)
            .setContentTitle(if (needsShizuku) "Shizuku isn't running" else "airhop")
            .setContentText(if (needsShizuku) "Tap to open Shizuku and start it (Wireless debugging)" else text)
            .setOngoing(true)
        if (needsShizuku) {
            packageManager.getLaunchIntentForPackage(SHIZUKU_PACKAGE)?.let {
                builder.setContentIntent(PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE))
            }
        }
        return builder.build()
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java).notify(1, notification(pods?.toString() ?: "waiting"))
    }

    companion object {
        const val TAG = "airhop"
        @Volatile var instance: HopService? = null

        private const val PREF_AIRPODS = "airpods"
        private const val PREF_KEYS = "keys"
        private const val APPLE = 76
        private const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
        private const val SHIZUKU_GRACE_MS = 15_000L
        private const val AACP_UUID = "74ec2172-0bad-4d01-8f77-997b2be0722a"
        private const val STALE_MS = 15_000L
        private const val IDLE_GRACE_MS = 0L
        private const val IDLE_RETRY_MS = 10_000L
        private const val LOST_GRACE_MS = 600L
        private const val SETTLE_MS = 2_500L
        private const val BEACON_DEDUPE_MS = 3_000L
        private const val BEACON_MS = 3_000L
    }
}
