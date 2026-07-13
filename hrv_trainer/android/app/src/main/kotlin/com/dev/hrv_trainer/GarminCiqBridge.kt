package com.dev.hrv_trainer

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import com.garmin.android.connectiq.exception.InvalidStateException
import com.garmin.android.connectiq.exception.ServiceUnavailableException
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge fra Flutter e l'app Connect IQ sull'Instinct Solar 2X.
 *
 * Usa direttamente il Connect IQ Mobile SDK (com.garmin.connectiq) pubblicato
 * su Maven Central. Se Garmin Connect Mobile non è installato sul telefono,
 * il backend reale lancia ServiceUnavailableException all'init e ricadiamo
 * sul MockCiqBackend (simulatore RSA per sviluppo UI).
 */
class GarminCiqBridge(private val context: Context) {

    companion object {
        const val TAG = "GarminCiqBridge"

        /** UUID dell'app Connect IQ (manifest.xml lato watch). */
        const val CIQ_APP_UUID = "53acf5c77bd74bc1bd3475f41ffec345"

        /**
         * Finestra entro la quale, dopo un evento dal watch, assumiamo che
         * l'app CIQ sia ancora in foreground sull'orologio.
         *
         * Garmin ripropone il dialog "Avviare HRV Trainer? Solo una volta /
         * Sempre / No" ad ogni `openApplication`, e per app side-loaded la
         * scelta "Sempre" NON viene persistita (è whitelist firmata sullo
         * store). Quindi, se sappiamo che il watch ci ha già risposto di
         * recente (HR_SAMPLE / STATE / SESSION_SUMMARY), l'app è up: saltiamo
         * `openApplication` e mandiamo direttamente con `sendMessage`, niente
         * prompt. Soglia volutamente generosa per coprire pause fra un
         * assessment e il successivo senza riscatenare il dialog.
         */
        const val ASSUME_RUNNING_WINDOW_MS = 120_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var eventsSink: EventChannel.EventSink? = null

    private var realBackend: RealCiqBackend? = null
    private val mockBackend = MockCiqBackend(mainHandler)

    private val backend: CiqBackend
        get() = realBackend ?: mockBackend

    init {
        try {
            realBackend = RealCiqBackend(context, CIQ_APP_UUID).also {
                Log.i(TAG, "Connect IQ SDK init: modalita' REALE attiva")
                it.onEvent = { payload -> postEvent(payload) }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Init reale fallita (${t.javaClass.simpleName}: ${t.message}), uso mock", t)
        }
        mockBackend.onEvent = { payload -> postEvent(payload) }
        CiqDiag.append(context, "bridge init: backend=${if (realBackend != null) "real" else "mock"}")
    }

    val eventStreamHandler: EventChannel.StreamHandler =
        object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventsSink = events
                postEvent(
                    mapOf(
                        "type" to "STATE",
                        "v" to "READY",
                        "backend" to if (realBackend != null) "real" else "mock",
                    )
                )
            }

            override fun onCancel(arguments: Any?) {
                eventsSink = null
            }
        }

    fun start(hz: Int, pacer: Map<String, Any?>, result: MethodChannel.Result) {
        try {
            backend.start(hz, pacer)
            result.success(null)
        } catch (t: Throwable) {
            result.error("START_FAILED", t.message, null)
        }
    }

    fun stop(result: MethodChannel.Result) {
        try {
            backend.stop()
            result.success(null)
        } catch (t: Throwable) {
            result.error("STOP_FAILED", t.message, null)
        }
    }

    fun forceStop(result: MethodChannel.Result) {
        try {
            backend.forceStop()
            result.success(null)
        } catch (t: Throwable) {
            result.error("FORCE_STOP_FAILED", t.message, null)
        }
    }

    fun reconnect(result: MethodChannel.Result) {
        try {
            backend.reconnect()
            result.success(null)
        } catch (t: Throwable) {
            result.error("RECONNECT_FAILED", t.message, null)
        }
    }

    fun requestHrv(reqId: Int, result: MethodChannel.Result) {
        try {
            backend.requestHrv(reqId)
            result.success(null)
        } catch (t: Throwable) {
            result.error("HRV_FAILED", t.message, null)
        }
    }

    fun summaryAck(startMs: Long, result: MethodChannel.Result) {
        try {
            backend.summaryAck(startMs)
            result.success(null)
        } catch (t: Throwable) {
            result.error("ACK_FAILED", t.message, null)
        }
    }

    fun requestSync(force: Boolean, result: MethodChannel.Result) {
        try {
            backend.requestSync(force)
            result.success(null)
        } catch (t: Throwable) {
            result.error("SYNC_FAILED", t.message, null)
        }
    }

    fun listDevices(result: MethodChannel.Result) {
        try {
            result.success(backend.listDevices())
        } catch (t: Throwable) {
            result.error("LIST_FAILED", t.message, null)
        }
    }

    /** Append di una riga di diagnostica dal lato Dart (phone) al log persistente. */
    fun logDiag(msg: String, result: MethodChannel.Result) {
        CiqDiag.append(context, "phone   $msg")
        result.success(null)
    }

    private fun postEvent(payload: Map<String, Any?>) {
        mainHandler.post { eventsSink?.success(payload) }
    }

    fun dispose() {
        try { backend.dispose() } catch (_: Throwable) {}
        eventsSink = null
    }
}

/**
 * Contratto minimo che sia il backend reale che il mock devono implementare.
 */
internal interface CiqBackend {
    var onEvent: (Map<String, Any?>) -> Unit
    fun start(hz: Int, pacer: Map<String, Any?> = emptyMap())

    /**
     * Stop "leggero": invia STOP_SESSION con un semplice `sendMessage` diretto
     * (niente openApplication, quindi niente dialog "Avviare HRV Trainer?").
     * È la via veloce e silenziosa: funziona quando l'app sul watch è in
     * foreground (caso normale durante una sessione). Se il messaggio si perde
     * (watch tornato al watchface) il phone non riceve l'ACK STATE:READY e
     * ricade su [forceStop] — vedi handshake in GarminCiqSource.stop().
     */
    fun stop()

    /**
     * Stop "forte": openApplication + STOP_SESSION, come fa start(). Riporta
     * in foreground l'app sul watch se era stata backgroundata, così lo STOP
     * arriva davvero e l'orologio smette di campionare ("watch keeps running").
     * Usato solo come fallback quando lo [stop] diretto non è stato confermato.
     */
    fun forceStop()

    /**
     * Ri-aggancio esplicito al device: ri-scansiona i knownDevices, riassegna
     * il device handle e ri-registra i listener (device + app events). Serve
     * perché il handle viene altrimenti catturato una sola volta a onSdkReady
     * e mai più: dopo un drop/ripristino BT restava stale e start/stop/sync
     * fallivano in silenzio con NO_DEVICE finché non si riavviava l'app.
     */
    fun reconnect()

    fun requestHrv(reqId: Int)
    fun summaryAck(startMs: Long)

    /**
     * Chiede al watch di drenare il PendingStore (SESSION_SUMMARY non
     * confermati) ritrasmettendoli al phone.
     *
     * @param force se true, fa openApplication+sendMessage: sveglia l'app
     *   sul watch se non è in esecuzione (può triggerare il dialog
     *   "Avviare HRV Trainer?"). Usare per recovery esplicito quando
     *   l'utente preme un pulsante "Sincronizza".
     *   Se false, solo sendMessage diretto: silenzioso, no prompt.
     *   Se l'app sul watch non è running il messaggio si perde, ma è
     *   accettabile per i sync automatici (su app launch / lifecycle
     *   resume) per non infastidire l'utente.
     */
    fun requestSync(force: Boolean)
    fun listDevices(): List<Map<String, Any?>>
    fun dispose()
}

/* ----------------------------- MOCK ----------------------------- */

internal class MockCiqBackend(private val handler: Handler) : CiqBackend {
    override var onEvent: (Map<String, Any?>) -> Unit = {}
    private var active = false
    private var startNs = 0L

    override fun start(hz: Int, pacer: Map<String, Any?>) {
        if (active) return
        active = true
        startNs = System.nanoTime()
        onEvent(mapOf("type" to "STATE", "v" to "ACTIVE", "backend" to "mock"))
        val period = (1000.0 / hz.coerceIn(1, 10)).toLong()
        scheduleBeat(period)
    }

    private fun scheduleBeat(periodMs: Long) {
        handler.postDelayed({
            if (!active) return@postDelayed
            val elapsed = (System.nanoTime() - startNs) / 1e9
            val phase = Math.sin(2 * Math.PI * elapsed / 10.0)
            val bpm = (62 + 8 * phase + (Math.random() - 0.5)).toInt()
            val rr = (60000.0 / bpm).toInt()
            onEvent(mapOf(
                "type" to "HR_SAMPLE",
                "t" to System.currentTimeMillis(),
                "bpm" to bpm,
                "rr" to rr,
            ))
            scheduleBeat(periodMs)
        }, periodMs)
    }

    override fun stop() {
        active = false
        // stopped:true → il phone chiude l'handshake di stop senza fallback.
        onEvent(mapOf("type" to "STATE", "v" to "READY", "stopped" to true))
    }

    override fun forceStop() {
        // Mock: nessuna differenza con stop diretto.
        stop()
    }

    override fun reconnect() {
        // Mock sempre "connesso": ri-emette READY.
        onEvent(mapOf("type" to "STATE", "v" to "READY", "backend" to "mock"))
    }

    override fun requestHrv(reqId: Int) {
        handler.postDelayed({
            if (!active) return@postDelayed
            val rr = IntArray(60) { 900 + ((Math.random() - 0.5) * 120).toInt() }
            val mean = rr.average()
            val sdnn = Math.sqrt(rr.map { (it - mean) * (it - mean) }.average())
            var sq = 0.0
            for (i in 1 until rr.size) {
                val d = rr[i] - rr[i - 1]; sq += d * d
            }
            val rmssd = Math.sqrt(sq / (rr.size - 1))
            onEvent(mapOf(
                "type" to "HRV_RESULT",
                "reqId" to reqId,
                "t" to System.currentTimeMillis(),
                "rmssd" to rmssd.toInt(),
                "sdnn" to sdnn.toInt(),
                "rr" to rr.toList(),
            ))
        }, 1800)
    }

    override fun summaryAck(startMs: Long) {
        // Mock backend: nessuna sessione reale del watch da confermare.
    }

    override fun requestSync(force: Boolean) {
        // Mock backend: niente PendingStore, niente da drenare.
    }

    override fun listDevices(): List<Map<String, Any?>> =
        listOf(mapOf("id" to "mock-1", "name" to "Instinct Solar 2X (mock)"))

    override fun dispose() { active = false }
}

/* ----------------------------- REAL ----------------------------- */

/**
 * Backend che usa il SDK Connect IQ Mobile direttamente.
 *
 * Inizializza ConnectIQ in modalità WIRELESS, registra listener per eventi
 * device/app, espone start/stop/requestHrv come messaggi al watch.
 *
 * Si appoggia all'app Garmin Connect Mobile installata sul telefono. Senza
 * di essa, ConnectIQ.initialize lancia ServiceUnavailableException e il
 * GarminCiqBridge ricade sul mock.
 */
internal class RealCiqBackend(
    private val context: Context,
    private val appUuid: String,
) : CiqBackend {

    private val connectIq: ConnectIQ =
        ConnectIQ.getInstance(context, ConnectIQ.IQConnectType.WIRELESS)

    private val iqApp = IQApp(appUuid)

    @Volatile
    private var device: IQDevice? = null

    @Volatile
    private var sdkReady = false

    /**
     * Timestamp (epoch ms) dell'ultimo segnale di vita dal watch.
     * Aggiornato su:
     *  - qualunque payload ricevuto da `registerForAppEvents` (HR/STATE/SUMMARY)
     *  - status `APP_IS_ALREADY_RUNNING` da `openApplication`
     * Letto da `start()` per decidere se saltare il prompt "Avviare?".
     */
    @Volatile
    private var lastWatchActivityMs: Long = 0L

    // Loggato una volta per sessione: "il primo HR_SAMPLE è arrivato" = il link
    // watch→phone è davvero vivo. Reset ad ogni start(). Diagnostica.
    @Volatile
    private var sawFirstSample = false

    /** Riga di diagnostica lato nativo verso il log persistente (best-effort). */
    private fun diag(line: String) = CiqDiag.append(context, "native  $line")

    // Handler sul main looper per il fallback temporizzato dello START (vedi start()).
    private val handler = Handler(Looper.getMainLooper())

    override var onEvent: (Map<String, Any?>) -> Unit = {}

    private val sdkListener = object : ConnectIQ.ConnectIQListener {
        override fun onSdkReady() {
            Log.i(GarminCiqBridge.TAG, "CIQ SDK ready")
            sdkReady = true
            refreshKnownDevices()
        }

        override fun onInitializeError(errStatus: ConnectIQ.IQSdkErrorStatus) {
            Log.e(GarminCiqBridge.TAG, "CIQ init error: $errStatus")
            diag("SDK init ERROR: ${errStatus.name}")
            onEvent(mapOf("type" to "STATE", "v" to "ERROR", "msg" to errStatus.name))
        }

        override fun onSdkShutDown() {
            sdkReady = false
            // SDK spento: non possiamo più assumere che l'app sul watch giri.
            lastWatchActivityMs = 0L
            diag("SDK shutdown -> DISCONNECTED")
            onEvent(mapOf("type" to "STATE", "v" to "DISCONNECTED"))
        }
    }

    init {
        // Può lanciare ServiceUnavailableException se Garmin Connect Mobile
        // non è installato — il caller catcha e ricade su mock.
        connectIq.initialize(context, true, sdkListener)
    }

    private fun refreshKnownDevices() {
        // Unregistra i listener del device precedente PRIMA di riassegnare:
        // senza questo, ogni reconnect/refresh accumulerebbe registrazioni
        // duplicate (listener leak) e potrebbe consegnare eventi verso un
        // handle stale.
        device?.let { old ->
            try { connectIq.unregisterForDeviceEvents(old) } catch (_: Throwable) {}
            try { connectIq.unregisterForApplicationEvents(old, iqApp) } catch (_: Throwable) {}
        }

        val devices: List<IQDevice> = try {
            connectIq.knownDevices ?: emptyList()
        } catch (t: Throwable) {
            Log.w(GarminCiqBridge.TAG, "knownDevices failed", t)
            emptyList()
        }
        Log.i(GarminCiqBridge.TAG, "knownDevices count=${devices.size}: " +
            devices.joinToString { "${it.friendlyName}(${it.deviceIdentifier},${it.status?.name})" })
        val first = devices.firstOrNull()
        device = first
        diag("refresh: knownDevices=${devices.size} first=${first?.friendlyName}(${first?.status?.name})")
        if (first != null) {
            registerDeviceEvents(first)
            registerAppEvents(first)
            if (first.status != IQDevice.IQDeviceStatus.CONNECTED) {
                // Device noto ma non connesso al refresh (tipico al resume): la
                // finestra "app sicuramente in esecuzione" non è affidabile, va
                // azzerata altrimenti il prossimo start() salterebbe
                // openApplication su un watch irraggiungibile. Vedi deviceEvent.
                lastWatchActivityMs = 0L
            }
            // Emettiamo lo stato REALE del device (non un READY incondizionato):
            // knownDevices può contenere un watch accoppiato ma NON connesso.
            emitDeviceState(first.status, describeDevice(first))
        } else {
            lastWatchActivityMs = 0L
            diag("refresh: NO_DEVICE (nessun orologio noto)")
            onEvent(mapOf("type" to "STATE", "v" to "NO_DEVICE", "backend" to "real"))
        }
    }

    /**
     * Traduce lo `IQDeviceStatus` grezzo del SDK nel vocabolario di protocollo
     * che il lato Dart sa interpretare.
     *
     * CRITICO (root cause raw-device-status-maps-to-disconnected): prima si
     * inoltrava `status.name` grezzo (CONNECTED / NOT_CONNECTED / NOT_PAIRED /
     * UNKNOWN). Lo switch Dart riconosceva solo READY/ACTIVE/ERROR e mandava
     * tutto il resto in `disconnected`: così un evento CONNECTED (orologio
     * tornato raggiungibile!) faceva mostrare "Disconnesso" sul telefono.
     *
     * Mappatura:
     *   CONNECTED                -> DEVICE_CONNECTED   (Dart: connected)
     *   NOT_CONNECTED/NOT_PAIRED -> DEVICE_DISCONNECTED (Dart: disconnected)
     *   UNKNOWN / null           -> nessun evento (transitorio: keep-current)
     */
    private fun emitDeviceState(
        status: IQDevice.IQDeviceStatus?,
        deviceInfo: Map<String, Any?>? = null,
    ) {
        when (status) {
            IQDevice.IQDeviceStatus.CONNECTED ->
                onEvent(mapOf(
                    "type" to "STATE",
                    "v" to "DEVICE_CONNECTED",
                    "backend" to "real",
                    "device" to deviceInfo,
                ))
            IQDevice.IQDeviceStatus.NOT_CONNECTED,
            IQDevice.IQDeviceStatus.NOT_PAIRED ->
                onEvent(mapOf("type" to "STATE", "v" to "DEVICE_DISCONNECTED", "backend" to "real"))
            else ->
                // UNKNOWN o null: stato transitorio, non forziamo disconnessione.
                Log.i(GarminCiqBridge.TAG, "device status transient/ignored: ${status?.name}")
        }
    }

    private fun registerDeviceEvents(dev: IQDevice) {
        try {
            connectIq.registerForDeviceEvents(dev) { d, status ->
                Log.i(GarminCiqBridge.TAG, "deviceEvent ${d?.friendlyName} status=${status?.name}")
                diag("deviceEvent ${d?.friendlyName} status=${status?.name}")
                when (status) {
                    IQDevice.IQDeviceStatus.CONNECTED -> {
                        // Watch tornato raggiungibile dopo un drop BT: riaggancia
                        // il handle e ri-registra gli app-events (idempotente)
                        // così gli HR_SAMPLE riprendono a fluire senza riavviare.
                        device = dev
                        registerAppEvents(dev)
                    }
                    IQDevice.IQDeviceStatus.NOT_CONNECTED,
                    IQDevice.IQDeviceStatus.NOT_PAIRED -> {
                        // Device non più raggiungibile: la finestra assume-running
                        // è ora stale. Azzerarla forza openApplication al prossimo
                        // start() — l'unico modo di risvegliare l'app sul watch.
                        // Senza, START_SESSION cadrebbe nel vuoto e il phone
                        // abortirebbe a 35s con "nessun dato" pur col watch acceso.
                        lastWatchActivityMs = 0L
                    }
                    else -> {} // UNKNOWN / null: transitorio, non tocchiamo nulla.
                }
                emitDeviceState(status, describeDevice(dev))
            }
        } catch (_: InvalidStateException) {}
    }

    private fun registerAppEvents(dev: IQDevice) {
        // NON smontare prima di registrare. Su questo SDK Connect IQ
        // registerForAppEvents è keyed per (device, app): se il receiver esiste
        // già fa solo un setAppListener(...) e ritorna (nessuna callback
        // duplicata, nessun BroadcastReceiver in più). L'unregister preventivo
        // invece azzerava l'appListener PRIMA del register; se quest'ultimo
        // lanciava InvalidStateException (tipico proprio all'istante di un
        // deviceEvent CONNECTED, con l'SDK in transizione BT) il listener
        // restava NULL su un receiver ancora vivo → telefono sordo, stallo dei
        // battiti a orologio acceso (Sintomo "grafico bloccato + Connessione
        // persa"). Registrando senza smontare, un register fallito lascia
        // intatto il listener funzionante. La pulizia cross-device è già gestita
        // da refreshKnownDevices (unregisterForApplicationEvents sul device vecchio).
        try {
            connectIq.registerForAppEvents(dev, iqApp) { _, _, message, status ->
                Log.i(GarminCiqBridge.TAG,
                    "appEvent received status=${status?.name} msgSize=${message?.size}")
                // message è una List<Any?>; il watch invia un singolo dict.
                val payload = message?.firstOrNull() as? Map<String, Any?>
                if (payload != null) {
                    val ptype = payload["type"] as? String
                    Log.i(GarminCiqBridge.TAG, "appEvent payload type=$ptype")
                    // SOLO un HR_SAMPLE (sessione attiva, app in foreground che
                    // streamma) autorizza a saltare openApplication al prossimo
                    // start(). Un ack STATE (es. lo stop) NON prova che l'app
                    // resterà in foreground per il prossimo START: contarlo faceva
                    // sì che un retry dopo una sessione CADUTA saltasse il
                    // risveglio e mandasse lo START nel vuoto (log 07-11 sera,
                    // sessione 2). openApplication invece ristabilisce/conferma il
                    // canale (APP_IS_ALREADY_RUNNING, senza dialog, se l'app è su).
                    if (ptype == "HR_SAMPLE") {
                        lastWatchActivityMs = System.currentTimeMillis()
                        if (!sawFirstSample) {
                            sawFirstSample = true
                            diag("watch -> primo HR_SAMPLE ricevuto (link vivo)")
                        }
                    } else {
                        diag("watch -> $ptype")
                    }
                    onEvent(payload)
                } else {
                    Log.w(GarminCiqBridge.TAG,
                        "appEvent payload null or wrong type: ${message?.firstOrNull()}")
                }
            }
            Log.i(GarminCiqBridge.TAG, "registerForAppEvents OK for ${dev.friendlyName}")
        } catch (e: InvalidStateException) {
            Log.e(GarminCiqBridge.TAG, "registerForAppEvents InvalidStateException", e)
            diag("registerForAppEvents FALLITO (InvalidStateException) — il listener precedente resta attivo")
        }
    }

    override fun reconnect() {
        Log.i(GarminCiqBridge.TAG, "reconnect requested (sdkReady=$sdkReady)")
        diag("reconnect requested (sdkReady=$sdkReady)")
        if (!sdkReady) {
            // SDK non ancora pronto: ritenta l'init. Se Garmin Connect Mobile
            // manca, initialize rilancia e onInitializeError informa la UI.
            try {
                connectIq.initialize(context, true, sdkListener)
            } catch (t: Throwable) {
                Log.e(GarminCiqBridge.TAG, "reconnect: initialize failed", t)
                onEvent(mapOf("type" to "STATE", "v" to "ERROR", "msg" to (t.message ?: "init failed")))
            }
            return
        }
        refreshKnownDevices()
    }

    override fun start(hz: Int, pacer: Map<String, Any?>) {
        Log.i(GarminCiqBridge.TAG, "RealBackend.start hz=$hz pacer=$pacer device=${device?.friendlyName} status=${device?.status}")
        sawFirstSample = false
        diag("start richiesto (device=${device?.friendlyName} status=${device?.status})")
        val payload = mutableMapOf<String, Any?>("type" to "START_SESSION", "hz" to hz)
        payload.putAll(pacer)

        val dev = device
        if (dev == null) {
            Log.w(GarminCiqBridge.TAG, "start senza device disponibile")
            diag("start: NO_DEVICE (nessun device agganciato)")
            onEvent(mapOf("type" to "STATE", "v" to "NO_DEVICE"))
            return
        }

        // phoneTxMs viene aggiunto SOLO immediatamente prima di sendMessage,
        // NON nel payload pre-openApplication: openApplication può richiedere
        // fino a ~17 s (memoria progetto), e includerlo gonfierebbe il
        // round-trip stimato lato Dart, sovra-correggendo l'allineamento del
        // countdown phone↔watch. Misurato dal punto di invio BT, il round-trip
        // riflette solo δ_send + watch_processing + δ_recv → divisibile /2 con
        // simmetria up/down.
        val now = System.currentTimeMillis()
        val sinceLastSignal = now - lastWatchActivityMs
        val skipPrompt = lastWatchActivityMs > 0L &&
            sinceLastSignal < GarminCiqBridge.ASSUME_RUNNING_WINDOW_MS

        if (skipPrompt) {
            // Watch sicuramente up: skippiamo openApplication per non far
            // riapparire il dialog "Avviare HRV Trainer? Solo una volta /
            // Sempre / No" del firmware Garmin (su app side-loaded "Sempre"
            // non è persistente — vedi commento ASSUME_RUNNING_WINDOW_MS).
            Log.i(GarminCiqBridge.TAG,
                "start: skip openApplication (watch attivo da ${sinceLastSignal} ms)")
            diag("start: SALTO openApplication (watch attivo da ${sinceLastSignal}ms) — se l'app watch e' morta lo START va nel vuoto")
            val withTxMs = payload.toMutableMap().apply {
                put("phoneTxMs", System.currentTimeMillis())
            }
            sendToWatch(withTxMs)
            return
        }

        Log.i(GarminCiqBridge.TAG,
            "start: calling openApplication on ${dev.friendlyName} " +
            "(lastWatchActivity ${if (lastWatchActivityMs == 0L) "mai" else "${sinceLastSignal} ms fa"})")
        diag("start: openApplication su ${dev.friendlyName} (lastActivity=${if (lastWatchActivityMs == 0L) "mai" else "${sinceLastSignal}ms fa"})")

        // Sveglia l'app CIQ sul watch se non è già running, poi invia il
        // messaggio. Senza openApplication, sendMessage cade nel vuoto se
        // l'utente non ha aperto l'app HRV Trainer manualmente sull'orologio.
        // START va inviato dentro il callback di openApplication. Sul campo
        // (log ciq_diag) si è però visto che a volte quel callback NON scatta:
        // openApplication tenta comunque il risveglio dell'app sul watch, ma
        // senza callback il START non partiva mai e la misura falliva in
        // silenzio (nessun HR_SAMPLE, l'utente annullava). Guardia atomica +
        // fallback temporizzato: chi arriva primo (callback o timeout) invia una
        // sola volta. Un eventuale doppio START è gestito dal watch (reset pulito).
        val startDispatched = java.util.concurrent.atomic.AtomicBoolean(false)
        fun dispatchStart(reason: String) {
            if (!startDispatched.compareAndSet(false, true)) return
            diag("START inviato ($reason)")
            val withTxMs = payload.toMutableMap().apply {
                put("phoneTxMs", System.currentTimeMillis())
            }
            sendToWatch(withTxMs)
        }
        try {
            connectIq.openApplication(dev, iqApp) { _, _, status ->
                Log.i(GarminCiqBridge.TAG, "openApplication status=${status.name}")
                diag("openApplication status=${status.name}")
                // Se l'app risulta già running possiamo aggiornare la finestra
                // assume-running anche senza aver ancora ricevuto un payload.
                if (status.name == "APP_IS_ALREADY_RUNNING") {
                    lastWatchActivityMs = System.currentTimeMillis()
                }
                dispatchStart("callback ${status.name}")
            }
        } catch (t: Throwable) {
            Log.e(GarminCiqBridge.TAG, "openApplication failed, provo send diretto", t)
            dispatchStart("openApplication FAIL")
        }
        // Fallback: se il callback non è arrivato entro 3.5s, inviamo comunque
        // (openApplication ha comunque tentato il risveglio). No-op se il
        // callback ha già inviato — la guardia atomica evita il doppio invio.
        handler.postDelayed({ dispatchStart("fallback timeout 3.5s") }, 3500)
    }

    override fun stop() {
        // Stop "leggero": sendMessage diretto, niente openApplication → niente
        // dialog. Funziona quando l'app sul watch è in foreground (caso normale).
        // Se il watch è tornato al watchface il messaggio si perde; il phone non
        // riceve l'ACK STATE:READY(stopped) e ricade su forceStop().
        sendToWatch(mapOf("type" to "STOP_SESSION"))
    }

    override fun forceStop() {
        Log.i(GarminCiqBridge.TAG, "forceStop: openApplication-backed STOP_SESSION")
        val dev = device
        if (dev == null) {
            Log.w(GarminCiqBridge.TAG, "forceStop senza device disponibile")
            onEvent(mapOf("type" to "STATE", "v" to "NO_DEVICE"))
            return
        }
        val payload = mapOf<String, Any?>("type" to "STOP_SESSION")
        // openApplication riporta in foreground l'app CIQ se era stata
        // backgroundata (watchface timeout): solo così lo STOP arriva e
        // l'orologio smette di campionare. Su app già attiva ritorna
        // APP_IS_ALREADY_RUNNING senza prompt.
        try {
            connectIq.openApplication(dev, iqApp) { _, _, status ->
                Log.i(GarminCiqBridge.TAG, "forceStop openApp status=${status.name}")
                if (status.name == "APP_IS_ALREADY_RUNNING") {
                    lastWatchActivityMs = System.currentTimeMillis()
                }
                sendToWatch(payload)
            }
        } catch (t: Throwable) {
            Log.e(GarminCiqBridge.TAG, "forceStop openApplication failed, send diretto", t)
            sendToWatch(payload)
        }
    }

    override fun requestHrv(reqId: Int) {
        sendToWatch(mapOf("type" to "REQUEST_HRV", "reqId" to reqId))
    }

    override fun summaryAck(startMs: Long) {
        // Conferma al watch che il SESSION_SUMMARY con questo startMs è
        // stato ricevuto e persistito sul phone, così può svuotare il
        // PendingStore locale e non ritrasmetterlo più.
        sendToWatch(mapOf("type" to "SUMMARY_ACK", "startMs" to startMs))
    }

    override fun requestSync(force: Boolean) {
        val dev = device
        if (dev == null) {
            Log.w(GarminCiqBridge.TAG, "requestSync: nessun device disponibile (force=$force)")
            return
        }
        val payload = mapOf("type" to "SYNC_REQUEST")

        if (!force) {
            // Sync silenzioso: niente openApplication.
            // Se l'app sul watch è running riceve e fa flush; altrimenti il
            // messaggio si perde. Accettabile per auto-sync su lifecycle.
            Log.i(GarminCiqBridge.TAG, "requestSync(force=false): sendMessage diretto")
            sendToWatch(payload)
            return
        }

        // Force=true: l'utente ha premuto un bottone esplicito.
        // openApplication può scatenare il dialog "Avviare HRV Trainer?"
        // sul watch — fastidioso ma accettato dall'utente in cambio del
        // recovery di summary che altrimenti resterebbero orfani.
        Log.i(GarminCiqBridge.TAG, "requestSync(force=true): openApplication + sendMessage")
        try {
            connectIq.openApplication(dev, iqApp) { _, _, status ->
                Log.i(GarminCiqBridge.TAG, "requestSync openApp status=${status.name}")
                if (status.name == "APP_IS_ALREADY_RUNNING") {
                    lastWatchActivityMs = System.currentTimeMillis()
                }
                sendToWatch(payload)
            }
        } catch (t: Throwable) {
            Log.e(GarminCiqBridge.TAG, "requestSync openApplication failed, send diretto", t)
            sendToWatch(payload)
        }
    }

    override fun listDevices(): List<Map<String, Any?>> {
        val devices = try {
            connectIq.knownDevices ?: emptyList<IQDevice>()
        } catch (_: Throwable) { emptyList() }
        return devices.map(::describeDevice)
    }

    private fun describeDevice(dev: IQDevice): Map<String, Any?> = mapOf(
        "id" to dev.deviceIdentifier,
        "name" to dev.friendlyName,
        "status" to dev.status?.name,
    )

    private fun sendToWatch(payload: Map<String, Any?>) {
        val dev = device
        if (dev == null) {
            Log.w(GarminCiqBridge.TAG, "sendToWatch senza device disponibile")
            return
        }
        try {
            connectIq.sendMessage(dev, iqApp, payload) { _, _, status ->
                Log.d(GarminCiqBridge.TAG, "sendMessage status=${status.name}")
            }
        } catch (_: InvalidStateException) {
            Log.e(GarminCiqBridge.TAG, "sendMessage: SDK non in stato valido")
        } catch (_: ServiceUnavailableException) {
            Log.e(GarminCiqBridge.TAG, "sendMessage: Garmin Connect Mobile non disponibile")
        } catch (t: Throwable) {
            Log.e(GarminCiqBridge.TAG, "sendMessage failed", t)
        }
    }

    override fun dispose() {
        device?.let {
            try { connectIq.unregisterForDeviceEvents(it) } catch (_: Throwable) {}
            try { connectIq.unregisterForApplicationEvents(it, iqApp) } catch (_: Throwable) {}
        }
        try { connectIq.shutdown(context) } catch (_: Throwable) {}
        sdkReady = false
    }
}

/**
 * Log di diagnostica persistente su file, pullabile via adb anche giorni dopo
 * (a differenza di logcat, che ha un ring buffer corto e ruota in poche ore).
 * Path: /sdcard/Android/data/com.dev.hrv_trainer/files/ciq_diag.log (+ .1 di
 * rotazione). Solo eventi a bassa frequenza (connessione/handshake), niente
 * HR_SAMPLE per-battito. Non deve MAI lanciare: la diagnostica non rompe l'app.
 */
internal object CiqDiag {
    private val lock = Any()
    private val fmt = java.text.SimpleDateFormat("MM-dd HH:mm:ss.SSS", java.util.Locale.US)
    private const val MAX_BYTES = 128 * 1024L

    fun append(context: Context, line: String) {
        synchronized(lock) {
            try {
                val dir = context.getExternalFilesDir(null) ?: return
                val f = java.io.File(dir, "ciq_diag.log")
                if (f.length() > MAX_BYTES) {
                    val bak = java.io.File(dir, "ciq_diag.log.1")
                    if (bak.exists()) bak.delete()
                    f.renameTo(bak)
                }
                java.io.FileWriter(f, true).use {
                    it.append(fmt.format(java.util.Date())).append("  ").append(line).append('\n')
                }
            } catch (_: Throwable) {
                // best-effort: la diagnostica non deve mai rompere l'app.
            }
        }
    }
}
