package com.dev.hrv_trainer

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val methodChannelName = "dev.hrv/garmin_ciq"
    private val eventChannelName = "dev.hrv/garmin_ciq_events"

    private var bridge: GarminCiqBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val b = GarminCiqBridge(applicationContext)
        bridge = b

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val hz = (call.argument<Int>("hz") ?: 4)
                        val pacer = mapOf(
                            "inhaleMs" to call.argument<Int>("inhaleMs"),
                            "exhaleMs" to call.argument<Int>("exhaleMs"),
                            "hold1Ms" to call.argument<Int>("hold1Ms"),
                            "hold2Ms" to call.argument<Int>("hold2Ms"),
                            "durationSec" to call.argument<Int>("durationSec"),
                        ).filterValues { it != null }
                        b.start(hz, pacer, result)
                    }
                    "stop" -> b.stop(result)
                    "requestHrv" -> {
                        val reqId = call.argument<Int>("reqId") ?: 0
                        b.requestHrv(reqId, result)
                    }
                    "summaryAck" -> {
                        // startMs è epoch ms: usa Long, non Int (overflow nel 2038).
                        val startMs = call.argument<Number>("startMs")?.toLong() ?: 0L
                        b.summaryAck(startMs, result)
                    }
                    "requestSync" -> {
                        val force = call.argument<Boolean>("force") ?: false
                        b.requestSync(force, result)
                    }
                    "listDevices" -> b.listDevices(result)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(b.eventStreamHandler)
    }

    override fun onDestroy() {
        bridge?.dispose()
        bridge = null
        super.onDestroy()
    }
}
