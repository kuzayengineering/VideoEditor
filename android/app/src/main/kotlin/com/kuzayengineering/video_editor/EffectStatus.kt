package com.kuzayengineering.video_editor

import android.os.SystemClock
import android.util.Log

/**
 * What the frame-by-frame look effects (Eye color, Outfit, Recolor) are
 * doing, for the editor to show: how long the oldest frame has been waiting
 * for its model (loading the model, or finding people in it), and the last
 * thing that went wrong, in words.
 */
object EffectStatus {
    private class Job(val startMs: Long, val label: String)

    private val open = HashMap<Long, Job>()
    private var next = 0L

    @Volatile
    var error: String? = null
        private set

    @Synchronized
    fun start(label: String): Long {
        val id = next++
        open[id] = Job(SystemClock.uptimeMillis(), label)
        return id
    }

    @Synchronized
    fun end(id: Long) {
        open.remove(id)
    }

    /** The waiting effect and for how long (ms), or null when none waits. */
    @Synchronized
    fun busy(): Pair<String, Long>? {
        val now = SystemClock.uptimeMillis()
        // (A frame dropped by a player that was let go never finishes.)
        open.entries.removeAll { now - it.value.startMs > 120_000 }
        val oldest = open.values.minByOrNull { it.startMs } ?: return null
        return oldest.label to (now - oldest.startMs)
    }

    fun fail(label: String, t: Throwable) {
        Log.e("VideoEditor", "$label failed", t)
        var root: Throwable = t
        while (root.cause != null && root.cause !== root) root = root.cause!!
        val why = (root.javaClass.simpleName + ": " + (root.message?.lineSequence()?.firstOrNull() ?: ""))
            .take(160)
        error = "$label couldn't run on this video ($why)."
    }

    fun failText(text: String) {
        error = text
    }

    fun clearError() {
        error = null
    }
}
