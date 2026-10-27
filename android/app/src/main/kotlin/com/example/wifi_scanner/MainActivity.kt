package com.example.wifi_scanner

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CH = "wifi_scan"
    private lateinit var wm: WifiManager
    private var rx: BroadcastReceiver? = null
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        MethodChannel(engine.dartExecutor.binaryMessenger, CH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startScan" -> startScan(result)
                    "isWifiEnabled" -> result.success(wm.isWifiEnabled)
                    else -> result.notImplemented()
                }
            }
    }

    private fun startScan(result: MethodChannel.Result) {
        if (!wm.isWifiEnabled) {
            result.error("WIFI_OFF", "Wi-Fi is off", null)
            return
        }
        pending = result
        if (rx == null) {
            rx = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context?, intent: Intent?) {
                    if (intent?.action != WifiManager.SCAN_RESULTS_AVAILABLE_ACTION) return
                    val ok = intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, false)
                    if (ok) {
                        val list = wm.scanResults.map { r ->
                            mapOf(
                                "ssid" to (r.SSID ?: ""),
                                "bssid" to r.BSSID,
                                "rssi" to r.level,
                                "frequency" to r.frequency,
                                "channel" to freqToChannel(r.frequency),
                                "capabilities" to r.capabilities
                            )
                        }
                        pending?.success(list)
                    } else {
                        pending?.error("SCAN_FAILED", "Results not updated", null)
                    }
                    pending = null
                }
            }
            registerReceiver(rx, IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION))
        }
        wm.startScan()
    }

    private fun freqToChannel(f: Int) = when {
        f == 2484 -> 14
        f in 2412..2472 -> (f - 2407) / 5
        f in 5000..5900 -> (f - 5000) / 5
        f in 5955..7115 -> (f - 5950) / 5
        else -> 0
    }

    override fun onDestroy() {
        rx?.let { unregisterReceiver(it) }
        super.onDestroy()
    }
}
