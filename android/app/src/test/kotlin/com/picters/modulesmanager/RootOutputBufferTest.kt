package com.picters.modulesmanager

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class RootOutputBufferTest {
    @Test fun largeThermalOutputSurvivesInterleavedReplies() {
        val replies = RootOutputBuffer()
        val thermal = "thermal-normal.conf|" + "a".repeat(1_212_536) + "\n🌡️"
        replies.start(1)
        replies.start(2)
        thermal.chunked(8192).forEach { replies.append(1, it) }
        replies.append(2, "target=stock")
        assertEquals("target=stock", replies.finish(2, ""))
        assertEquals(thermal, replies.finish(1, ""))
    }

    @Test fun failedOrExpiredRequestsDoNotRetainLateChunks() {
        val replies = RootOutputBuffer()
        replies.start(1)
        replies.append(1, "partial")
        replies.remove(1)
        replies.append(1, "late")
        assertEquals("", replies.finish(1, ""))
    }

    @Test fun rejectsExcessiveOutput() {
        val replies = RootOutputBuffer()
        replies.start(1)
        replies.append(1, "a".repeat(RootOutputBuffer.MAX_CHARS))
        try {
            replies.append(1, "b")
            fail("Expected size rejection")
        } catch (_: IllegalStateException) { }
    }
}
