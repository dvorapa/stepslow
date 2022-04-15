package cz.dvorapa.stepslow

import android.content.Intent
import android.os.Bundle
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity: FlutterActivity() {
  private val BRIDGE = "cz.dvorapa.stepslow/sharedPath";

  var openSharedPath: String ?= null
  override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    val bridge = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BRIDGE)
    bridge.setMethodCallHandler {
      call,
      result -> when(call.method) {
        "openSharedPath" -> {
          result.success(openSharedPath)
        }
        else -> result.notImplemented()
      }
    }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    handleSharedPath(intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    handleSharedPath(intent)
  }

  private fun handleSharedPath(intent: Intent?) {
    val sharedPath = intent?.data?.path
    if (sharedPath != null) {
      openSharedPath = sharedPath
    }
  }
}
