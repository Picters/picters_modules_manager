package com.picters.modulesmanager

import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import com.topjohnwu.superuser.ipc.RootService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

private const val CHANNEL = "com.picters.modulesmanager/system"
private const val ROOT_EVENTS = "com.picters.modulesmanager/system/root_events"

class MainActivity : FlutterActivity() {

    private val mainHandler = Handler(Looper.getMainLooper())

    // ── Root service (AIDL/Binder) bridge ────────────────────────────────────
    private var kernelService: IKernelService? = null
    private var rootSink: EventChannel.EventSink? = null
    private var bindPending: MethodChannel.Result? = null

    private val rootConn = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            kernelService = IKernelService.Stub.asInterface(service)
            Log.i("PKM_IPC", "onServiceConnected: apiVersion=${runCatching { kernelService?.apiVersion }.getOrNull()}")
            bindPending?.success(true)
            bindPending = null
        }

        override fun onServiceDisconnected(name: ComponentName) {
            Log.w("PKM_IPC", "onServiceDisconnected")
            kernelService = null
        }

        override fun onBindingDied(name: ComponentName?) {
            Log.w("PKM_IPC", "onBindingDied")
            kernelService = null
            bindPending?.success(false)
            bindPending = null
        }
    }

    // Results/errors from the root process arrive on a Binder thread; forward
    // them to the Flutter event sink on the main thread.
    private val execCallback = object : IExecCallback.Stub() {
        override fun onComplete(requestId: Int, exitCode: Int, output: String?) {
            mainHandler.post {
                rootSink?.success(
                    mapOf("id" to requestId, "code" to exitCode, "out" to (output ?: "")),
                )
            }
        }

        override fun onError(requestId: Int, message: String?) {
            mainHandler.post {
                rootSink?.success(mapOf("id" to requestId, "err" to (message ?: "error")))
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, ROOT_EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    rootSink = events
                }

                override fun onCancel(arguments: Any?) {
                    rootSink = null
                }
            },
        )

        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPinShortcut" -> result.success(requestPinShortcut())
                "openRootManager" -> result.success(openRootManager())
                "bindRoot" -> bindRootService(result)
                "execRoot" -> execRoot(
                    call.argument("id"),
                    call.argument("script"),
                    call.argument("timeoutMs"),
                    result,
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun bindRootService(result: MethodChannel.Result) {
        if (kernelService != null) {
            result.success(true)
            return
        }
        try {
            bindPending = result
            Log.i("PKM_IPC", "bindRoot: starting RootService.bind")
            RootService.bind(Intent(this, KernelRootService::class.java), rootConn)
            // onServiceConnected/onBindingDied completes `result`; the Dart side
            // also guards with its own timeout in case binding never resolves.
        } catch (t: Throwable) {
            bindPending = null
            result.success(false)
        }
    }

    private fun execRoot(id: Int?, script: String?, timeoutMs: Int?, result: MethodChannel.Result) {
        val svc = kernelService
        if (svc == null || id == null || script == null) {
            result.success(false)
            return
        }
        try {
            svc.exec(id, script, timeoutMs ?: 30000, execCallback)
            result.success(true)
        } catch (t: Throwable) {
            // Binder died — drop the reference so the app falls back to the pipe.
            kernelService = null
            result.success(false)
        }
    }

    /** Launcher package names of the common root managers, most likely first. */
    private val rootManagers = listOf(
        "me.weishu.kernelsu",   // KernelSU
        "me.bmax.apatch",       // APatch
        "com.topjohnwu.magisk", // Magisk
    )

    /**
     * Opens whichever root manager is installed so the user can grant Superuser
     * access, instead of leaving them to hunt for the app themselves. Returns
     * false only if none of the known managers is installed.
     */
    private fun openRootManager(): Boolean {
        val pm = packageManager
        for (pkg in rootManagers) {
            val intent = pm.getLaunchIntentForPackage(pkg) ?: continue
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            return true
        }
        return false
    }

    private fun requestPinShortcut(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val shortcutManager = getSystemService(ShortcutManager::class.java) ?: return false
        if (!shortcutManager.isRequestPinShortcutSupported) return false

        val launchIntent = Intent(Intent.ACTION_MAIN).apply {
            setClassName(this@MainActivity, "com.picters.modulesmanager.MainActivity")
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val shortcut = ShortcutInfo.Builder(this, "picters_modules_manager_shortcut")
            .setShortLabel("Modules Manager")
            .setLongLabel("Picters Modules Manager")
            .setIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
            .setIntent(launchIntent)
            .build()
        return shortcutManager.requestPinShortcut(shortcut, null)
    }
}
