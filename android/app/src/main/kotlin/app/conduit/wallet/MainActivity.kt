package app.conduit.wallet

import android.net.TrafficStats
import android.os.Process
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.conduit.wallet.eric/traffic",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getTrafficStats" -> {
                    val uid = Process.myUid()
                    result.success(
                        mapOf(
                            "rx" to TrafficStats.getUidRxBytes(uid),
                            "tx" to TrafficStats.getUidTxBytes(uid),
                        )
                    )
                }
                else -> result.notImplemented()
            }
        }
    }
}
