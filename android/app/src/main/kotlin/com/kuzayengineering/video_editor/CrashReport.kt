package com.kuzayengineering.video_editor

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Why the app last closed unexpectedly, to show the next time it opens (the
 * phone's own crash log can't be read without a computer). Nothing is sent
 * anywhere: the person can copy the text if they want to share it.
 */
object CrashReport {
    private const val FILE = "last_crash.txt"

    /** Keeps the details of a crash in the app's own code. */
    fun install(context: Context) {
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            try {
                File(app.filesDir, FILE).writeText(
                    "Thread: ${thread.name}\n" + Log.getStackTraceString(e).take(12_000),
                )
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(thread, e)
        }
    }

    /** A report of closings not shown before, or null. */
    fun unseen(context: Context): String? {
        val prefs = context.getSharedPreferences("crash_report2", Context.MODE_PRIVATE)
        val seen = prefs.getLong("seen", System.currentTimeMillis() - 60_000L * 60 * 24)
        var newest = seen
        val out = StringBuilder()
        val time = SimpleDateFormat("MMM d, HH:mm:ss", Locale.US)
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                val am = context.getSystemService(ActivityManager::class.java)
                for (x in am.getHistoricalProcessExitReasons(context.packageName, 0, 5)) {
                    if (x.timestamp <= seen) continue
                    val kind = when (x.reason) {
                        ApplicationExitInfo.REASON_CRASH -> "Crash (app code)"
                        ApplicationExitInfo.REASON_CRASH_NATIVE -> "Crash (native code)"
                        ApplicationExitInfo.REASON_ANR -> "Stopped responding"
                        ApplicationExitInfo.REASON_LOW_MEMORY -> "Closed by the phone: low memory"
                        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "Closed by the phone: too much use"
                        else -> null
                    } ?: continue
                    newest = maxOf(newest, x.timestamp)
                    out.append("$kind at ${time.format(Date(x.timestamp))}")
                    x.description?.let { out.append(": ").append(it) }
                    out.append(" (memory ${x.pss / 1024} MB)\n")
                    if (x.reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
                        x.reason == ApplicationExitInfo.REASON_ANR
                    ) {
                        x.traceInputStream?.use { stream ->
                            val bytes = stream.readBytes()
                            if (x.reason == ApplicationExitInfo.REASON_ANR) {
                                out.append(String(bytes).take(6000)).append('\n')
                            } else {
                                out.append(Tombstone.summary(bytes)).append('\n')
                            }
                        }
                    }
                }
            } catch (_: Throwable) {
            }
        }
        val file = File(context.filesDir, FILE)
        if (file.isFile && file.lastModified() > seen) {
            newest = maxOf(newest, file.lastModified())
            out.append("\nDetails:\n").append(file.readText())
        }
        prefs.edit().putLong("seen", maxOf(newest, System.currentTimeMillis())).apply()
        return out.toString().trim().ifEmpty { null }
    }
}

/**
 * Reads the parts that matter from the phone's crash record ("tombstone",
 * in Google's protobuf format): the stop message, the thread that stopped
 * and its call stack, and the app's last log lines.
 */
private object Tombstone {
    private class Reader(val b: ByteArray, var p: Int = 0, val end: Int = b.size) {
        fun more() = p < end
        fun varint(): Long {
            var r = 0L
            var shift = 0
            while (p < end) {
                val x = b[p++].toInt() and 0xff
                r = r or ((x and 0x7f).toLong() shl shift)
                if (x and 0x80 == 0) break
                shift += 7
            }
            return r
        }
        /** Calls [f] with (field, wire type, value or sub-reader). */
        fun each(f: (Int, Int, Long, Reader?) -> Unit) {
            while (more()) {
                val key = varint()
                val field = (key ushr 3).toInt()
                when ((key and 7).toInt()) {
                    0 -> f(field, 0, varint(), null)
                    1 -> { p += 8; f(field, 1, 0, null) }
                    5 -> { p += 4; f(field, 5, 0, null) }
                    2 -> {
                        val len = varint().toInt()
                        val sub = Reader(b, p, minOf(end, p + len))
                        p = minOf(end, p + len)
                        f(field, 2, 0, sub)
                    }
                    else -> return
                }
            }
        }
        fun text() = String(b, p, end - p, Charsets.UTF_8)
    }

    fun summary(bytes: ByteArray): String = try {
        val out = StringBuilder()
        var tid = -1L
        var abort = ""
        var signal = ""
        val threads = HashMap<Long, Pair<String, List<String>>>()
        val logs = mutableListOf<String>()
        Reader(bytes).each { f, _, v, r ->
            when (f) {
                6 -> tid = v
                14 -> abort = r!!.text()
                10 -> r!!.each { g, _, _, rr -> if (g == 2) signal = rr!!.text() }
                16 -> {
                    // map entry: key (1) thread id, value (2) Thread
                    var id = -1L
                    var name = ""
                    val frames = mutableListOf<String>()
                    r!!.each { g, _, vv, rr ->
                        if (g == 1) id = vv
                        if (g == 2) rr!!.each { h, _, _, t ->
                            when (h) {
                                2 -> name = t!!.text()
                                4 -> {
                                    var fn = ""
                                    var file = ""
                                    t!!.each { k, _, _, u ->
                                        if (k == 4) fn = u!!.text()
                                        if (k == 6) file = u!!.text().substringAfterLast('/')
                                    }
                                    frames += if (fn.isNotEmpty()) "$fn ($file)" else file
                                }
                            }
                        }
                    }
                    threads[id] = name to frames
                }
                18 -> r!!.each { g, _, _, rr ->
                    if (g == 2) {
                        var tag = ""
                        var msg = ""
                        var prio = 0L
                        rr!!.each { h, _, vv, t ->
                            if (h == 4) prio = vv
                            if (h == 5) tag = t!!.text()
                            if (h == 6) msg = t!!.text()
                        }
                        // Warnings and errors only (4 info, 5 warn, 6 error, 7 fatal).
                        if (prio >= 5) logs += "$tag: ${msg.trim()}"
                    }
                }
            }
        }
        if (signal.isNotEmpty()) out.append("  Signal: $signal\n")
        if (abort.isNotEmpty()) out.append("  Stop message: ${abort.take(1500)}\n")
        threads[tid]?.let { (name, frames) ->
            out.append("  Thread: $name\n")
            frames.take(40).forEach { out.append("    ").append(it.take(220)).append('\n') }
        }
        if (logs.isNotEmpty()) {
            out.append("  Last warnings:\n")
            logs.takeLast(40).forEach { out.append("    ").append(it.take(300)).append('\n') }
        }
        out.toString().trimEnd()
    } catch (t: Throwable) {
        "  (crash record unreadable: ${t.message})"
    }
}
