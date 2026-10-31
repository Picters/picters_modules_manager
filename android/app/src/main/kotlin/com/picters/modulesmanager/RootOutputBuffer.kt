package com.picters.modulesmanager

/** Reassembles bounded Binder parcels independently for concurrent root requests. */
internal class RootOutputBuffer {
    private val pending = mutableMapOf<Int, StringBuilder>()

    @Synchronized fun start(id: Int) { pending[id] = StringBuilder() }

    @Synchronized fun append(id: Int, text: String) {
        val buffer = pending[id] ?: return
        check(buffer.length + text.length <= MAX_CHARS) { "Root output exceeds the supported size" }
        buffer.append(text)
    }

    @Synchronized fun finish(id: Int, tail: String): String {
        append(id, tail)
        return pending.remove(id)?.toString() ?: tail
    }

    @Synchronized fun remove(id: Int) { pending.remove(id) }
    @Synchronized fun clear() { pending.clear() }

    companion object { const val MAX_CHARS = 16 * 1024 * 1024 }
}
