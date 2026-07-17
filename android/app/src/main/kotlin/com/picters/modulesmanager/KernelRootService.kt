package com.picters.modulesmanager

import android.content.Intent
import android.os.IBinder
import android.os.Process
import android.util.Log
import com.topjohnwu.superuser.ipc.RootService
import java.util.concurrent.TimeUnit

private const val TAG = "PKM_IPC"

/**
 * The root-side command broker.
 *
 * ## Registration scheme
 * This is **not** a global system service — a normal-UID app cannot call
 * `ServiceManager.addService()` (that needs a system/privileged SELinux domain
 * with `add` permission on the service context). Instead libsu's
 * [RootService.bind] bootstraps a dedicated **root process** (via `app_process`,
 * launched through the su daemon) that instantiates this class and hands its
 * Binder back to the app process over a private channel. From the app side it
 * behaves like `bindService()`, but the service runs as uid 0.
 *
 * ## No head-of-line blocking
 * Each [IKernelService.exec] runs on a thread from the Binder thread pool and is
 * `oneway`, so concurrent commands (e.g. a slow Wi-Fi switch and a fast scan)
 * execute in parallel and report back independently — unlike the single
 * serialized `su` stdin pipe, where everything queued behind the current command.
 */
class KernelRootService : RootService() {

    override fun onBind(intent: Intent): IBinder {
        Log.i(TAG, "RootService onBind: pid=${Process.myPid()} uid=${Process.myUid()}")
        return Impl()
    }

    private class Impl : IKernelService.Stub() {

        override fun getApiVersion(): Int = API_VERSION

        override fun exec(requestId: Int, script: String?, timeoutMs: Int, cb: IExecCallback?) {
            if (script == null || cb == null) return
            // This process is already root, so a plain `sh -c` is a root shell —
            // no `su` fork per call, and no SELinux audit spam from repeated su.
            try {
                val proc = ProcessBuilder("sh", "-c", script)
                    .redirectErrorStream(true)
                    .start()

                // Drain output on a side thread so a large payload can't deadlock
                // against waitFor() by filling the pipe buffer.
                val sb = StringBuilder()
                val reader = Thread {
                    try {
                        proc.inputStream.bufferedReader().forEachLine { sb.appendLine(it) }
                    } catch (_: Throwable) {
                    }
                }
                reader.start()

                val finished = proc.waitFor(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                if (!finished) {
                    proc.destroyForcibly()
                    reader.join(500)
                    cb.onError(requestId, "timeout after ${timeoutMs}ms")
                    return
                }
                reader.join(1000)
                cb.onComplete(requestId, proc.exitValue(), sb.toString().trimEnd('\n'))
            } catch (t: Throwable) {
                Log.w(TAG, "exec #$requestId failed", t)
                try {
                    cb.onError(requestId, t.message ?: t.toString())
                } catch (_: Throwable) {
                }
            }
        }
    }

    companion object {
        const val API_VERSION = 1
    }
}
