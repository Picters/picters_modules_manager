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

// Best-effort candidates only. ReSukiSU's own repo build.gradle.kts declares
// com.resukisu.resukisu, but a rebuilt/rebranded manager can still use a
// different, effectively unguessable package name — see the "randomized
// package names" note in Kokuban_Kernel_CI_Center's build.rs. If none of
// these match, openRootManager() just returns null and the Dart side falls
// back to telling the user to open their manager app manually.
private val KNOWN_MANAGER_PACKAGES = listOf(
    "com.resukisu.resukisu",
    "me.weishu.kernelsu",
)

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openRootManager" -> result.success(openRootManager())
                "requestPinShortcut" -> result.success(requestPinShortcut())
                else -> result.notImplemented()
            }
        }
    }

    private fun openRootManager(): String? {
        for (pkg in KNOWN_MANAGER_PACKAGES) {
            val intent = packageManager.getLaunchIntentForPackage(pkg) ?: continue
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            return pkg
        }
        return null
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
