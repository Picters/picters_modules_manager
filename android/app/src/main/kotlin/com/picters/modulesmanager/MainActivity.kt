package com.picters.modulesmanager

import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

private const val CHANNEL = "com.picters.modulesmanager/system"

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPinShortcut" -> result.success(requestPinShortcut())
                "openRootManager" -> result.success(openRootManager())
                else -> result.notImplemented()
            }
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
            .setShortLabel("Kernel Manager")
            .setLongLabel("Picters Kernel Manager")
            .setIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
            .setIntent(launchIntent)
            .build()
        return shortcutManager.requestPinShortcut(shortcut, null)
    }
}
