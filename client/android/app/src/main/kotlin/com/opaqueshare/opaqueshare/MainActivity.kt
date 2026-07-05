package com.opaqueshare.opaqueshare

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var safPlugin: SafStreamSavePlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val plugin = SafStreamSavePlugin(this).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
        }
        safPlugin = plugin
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        safPlugin?.detach()
        safPlugin = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        // Route the ACTION_CREATE_DOCUMENT result to the SAF plugin
        // before Flutter's own activity-result plumbing gets a look at
        // it — that plumbing doesn't know about our request code and
        // would just log a warning.
        val handled = safPlugin?.handleActivityResult(
            requestCode,
            resultCode,
            data,
        ) == true
        if (!handled) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
