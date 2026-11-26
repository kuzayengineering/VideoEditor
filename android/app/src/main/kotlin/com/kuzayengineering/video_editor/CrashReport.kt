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
        val prefs = context.getSharedPreferences("crash_report", Context.MODE_PRIVATE)
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
                            // The native report is binary: keep its readable
                            // lines about where it happened.
                            val buf = ByteArray(256 * 1024)
                            var n = 0
                            while (n < buf.size) {
                                val r = stream.read(buf, n, buf.size - n)
                                if (r <= 0) break
                                n += r
                            }
                            val bytes = buf.copyOf(n)
                            val lines = Regex("[\\x20-\\x7e]{6,}").findAll(String(bytes, Charsets.ISO_8859_1))
                                .map { it.value }
                                .filter {
                                    x.reason == ApplicationExitInfo.REASON_ANR ||
                                        it.contains(".so") || it.contains("Abort") ||
                                        it.contains("SIG") || it.contains("Java_") ||
                                        it.contains("art::") || it.contains("abort")
                                }
                                .distinct()
                                .take(60)
                                .toList()
                            lines.forEach { out.append("  ").append(it.take(200)).append('\n') }
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
