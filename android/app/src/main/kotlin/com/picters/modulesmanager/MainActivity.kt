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
                else -> result.notImplemented()
            }
        }
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
