package uz.azizbek.leopard

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The only activity of the app.
 *
 * It is a [FlutterFragmentActivity] because local_auth shows the system auth
 * prompt through androidx.biometric, which needs a FragmentActivity.
 */
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // FLAG_SECURE before the first frame: no screenshots, no screen
        // recording or casting of the window, and a blank card in the
        // recent-apps overview.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            setRecentsScreenshotEnabled(false)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CLIPBOARD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "copySensitive" -> {
                        val text = call.argument<String>("text")
                        if (text == null) {
                            result.error("bad_args", "text is required", null)
                        } else {
                            copySensitive(text)
                            result.success(null)
                        }
                    }
                    "clear" -> {
                        clearClipboard()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Copies [text] flagged as sensitive, so Android 13+ hides it in the
     * clipboard preview and keyboards do not offer it as a suggestion.
     */
    private fun copySensitive(text: String) {
        val clip = ClipData.newPlainText("", text)
        val extras = PersistableBundle()
        // ClipDescription.EXTRA_IS_SENSITIVE (API 33). The literal key is
        // the documented way to set it on older versions.
        val key =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ClipDescription.EXTRA_IS_SENSITIVE
            } else {
                "android.content.extra.IS_SENSITIVE"
            }
        extras.putBoolean(key, true)
        clip.description.extras = extras
        clipboard().setPrimaryClip(clip)
    }

    private fun clearClipboard() {
        val manager = clipboard()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.clearPrimaryClip()
        } else {
            manager.setPrimaryClip(ClipData.newPlainText("", ""))
        }
    }

    private fun clipboard(): ClipboardManager =
        getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    private companion object {
        const val CLIPBOARD_CHANNEL = "uz.azizbek.leopard/clipboard"
    }
}
