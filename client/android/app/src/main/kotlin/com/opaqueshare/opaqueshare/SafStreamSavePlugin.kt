package com.opaqueshare.opaqueshare

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import kotlin.concurrent.thread

/**
 * Native Storage Access Framework stream-save (ADR-0008).
 *
 * Two method calls over the "saf_stream_save" channel:
 *
 *  - `pickSaveUri(suggestedFilename)`: launches ACTION_CREATE_DOCUMENT
 *    via the classic `startActivityForResult` path and returns the
 *    chosen `content://` URI as a String (or null if the user
 *    cancelled). We use the classic activity-result path because
 *    Flutter's `FlutterActivity` extends bare `android.app.Activity`,
 *    not `androidx.activity.ComponentActivity`, so
 *    `ActivityResultRegistry` isn't available without swapping the
 *    activity class to `FlutterFragmentActivity` (deliberately avoided
 *    to minimise blast radius on theming / splash / plugin registration).
 *
 *  - `writeFileToUri(sourcePath, uri)`: opens the source file for
 *    read and the URI for write via ContentResolver, then copies in
 *    a 64 KiB loop on an I/O worker thread. Streams end-to-end, so
 *    peak heap is one buffer regardless of source size — the whole
 *    point of this plugin.
 *
 * We stay off the file_picker plugin's path for large files because
 * its Android backend only accepts `bytes:` (whole plaintext in
 * memory), which OOMs above ~200 MiB on mid-range devices (see
 * ADR-0006's "save step" discussion).
 */
class SafStreamSavePlugin(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.opaqueshare.opaqueshare/saf_stream_save"
        // Request code space reserved for this plugin. Kept high to
        // avoid collision with other plugins that also grab a
        // startActivityForResult slot.
        const val REQUEST_PICK_SAVE_URI = 0x517A
        private const val COPY_BUFFER_BYTES = 64 * 1024
    }

    private var channel: MethodChannel? = null

    /**
     * Held while a pickSaveUri round-trip is in flight. Cleared in
     * [handleActivityResult]. Guards against overlapping picks — the
     * receive screen only picks one file at a time, but a duplicate
     * call fails fast rather than shadowing the first.
     */
    private var pendingPickResult: MethodChannel.Result? = null

    fun attach(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler(this)
        channel = ch
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /**
     * Called by [MainActivity.onActivityResult] for any request code
     * this plugin owns. Returns true iff the event was consumed —
     * MainActivity should skip its `super.onActivityResult` in that
     * case to keep the Flutter engine's activity-result plumbing
     * uninvolved in our private URI.
     */
    fun handleActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        if (requestCode != REQUEST_PICK_SAVE_URI) return false
        val result = pendingPickResult
        pendingPickResult = null
        if (result == null) {
            // Nothing was waiting for us — spurious callback, drop.
            return true
        }
        if (resultCode != Activity.RESULT_OK) {
            // User backed out of the picker.
            result.success(null)
            return true
        }
        val uri = data?.data
        if (uri != null) {
            // Persist a write permission grant so subsequent
            // openOutputStream calls on the same URI succeed after
            // process death. Best-effort — some providers ignore
            // this.
            try {
                activity.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            } catch (_: SecurityException) {
                // Provider refused the persistable grant. The
                // immediate write still works via the ephemeral
                // grant tied to the intent result.
            }
        }
        result.success(uri?.toString())
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickSaveUri" -> handlePick(call, result)
            "writeFileToUri" -> handleWrite(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handlePick(call: MethodCall, result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error(
                "BUSY",
                "Another pickSaveUri call is already in flight.",
                null,
            )
            return
        }
        val suggestedFilename =
            call.argument<String>("suggestedFilename") ?: "opaqueshare"
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, suggestedFilename)
        }
        pendingPickResult = result
        try {
            activity.startActivityForResult(intent, REQUEST_PICK_SAVE_URI)
        } catch (t: Throwable) {
            pendingPickResult = null
            result.error(
                "LAUNCH_FAILED",
                t.message ?: "Could not launch the save dialog.",
                null,
            )
        }
    }

    private fun handleWrite(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        val uriStr = call.argument<String>("uri")
        if (sourcePath.isNullOrEmpty() || uriStr.isNullOrEmpty()) {
            result.error(
                "BAD_ARGS",
                "sourcePath and uri are required.",
                null,
            )
            return
        }
        val uri = try {
            Uri.parse(uriStr)
        } catch (t: Throwable) {
            result.error("BAD_URI", "Could not parse uri: $uriStr", null)
            return
        }
        val srcFile = File(sourcePath)
        if (!srcFile.exists()) {
            result.error(
                "SOURCE_MISSING",
                "Source file no longer exists: $sourcePath",
                null,
            )
            return
        }

        // Off the platform (main) thread — the copy is potentially
        // multi-second on multi-GB files. Result is reported back on
        // the main thread via runOnUiThread so Flutter's method
        // channel contract is satisfied.
        thread(name = "opaqueshare-saf-copy") {
            try {
                FileInputStream(srcFile).use { input ->
                    val output = activity.contentResolver.openOutputStream(
                        uri,
                        // "wt" = write + truncate. The URI was created
                        // just now via ACTION_CREATE_DOCUMENT, so
                        // "already exists" only happens on retry after
                        // a partial write; truncate is the right
                        // recovery.
                        "wt",
                    ) ?: throw IOException(
                        "ContentResolver returned no output stream for $uriStr",
                    )
                    output.use { out ->
                        val buffer = ByteArray(COPY_BUFFER_BYTES)
                        var read = input.read(buffer)
                        while (read >= 0) {
                            out.write(buffer, 0, read)
                            read = input.read(buffer)
                        }
                        out.flush()
                    }
                }
                activity.runOnUiThread { result.success(null) }
            } catch (t: Throwable) {
                activity.runOnUiThread {
                    result.error(
                        "WRITE_FAILED",
                        t.message ?: "Write failed.",
                        null,
                    )
                }
            }
        }
    }
}
