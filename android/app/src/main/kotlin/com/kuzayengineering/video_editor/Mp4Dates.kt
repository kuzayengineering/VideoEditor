package com.kuzayengineering.video_editor

import java.io.File
import java.io.RandomAccessFile

/**
 * Sets the recording date stored inside an MP4 file (the movie, track and
 * media headers), which is what galleries such as Google Photos sort by.
 */
object Mp4Dates {
    /** Seconds from 1904-01-01 (MP4's starting point) to 1970-01-01. */
    private const val FROM_1904 = 2_082_844_800L
    private val containers = setOf("moov", "trak", "mdia")
    private val headers = setOf("mvhd", "tkhd", "mdhd")

    fun set(file: File, epochMs: Long) {
        val seconds = epochMs / 1000 + FROM_1904
        RandomAccessFile(file, "rw").use { walk(it, 0, it.length(), seconds) }
    }

    private fun walk(f: RandomAccessFile, start: Long, end: Long, seconds: Long) {
        var pos = start
        val type = ByteArray(4)
        while (pos + 8 <= end) {
            f.seek(pos)
            var size = f.readInt().toLong() and 0xFFFFFFFFL
            f.readFully(type)
            var header = 8L
            if (size == 1L) {
                size = f.readLong()
                header = 16
            } else if (size == 0L) {
                size = end - pos
            }
            if (size < header || pos + size > end) return
            val name = String(type, Charsets.US_ASCII)
            if (name in containers) {
                walk(f, pos + header, pos + size, seconds)
            } else if (name in headers) {
                f.seek(pos + header)
                val version = f.read()
                f.skipBytes(3) // flags
                if (version == 1) {
                    f.writeLong(seconds) // created
                    f.writeLong(seconds) // modified
                } else {
                    f.writeInt(seconds.toInt()) // (unsigned 32-bit)
                    f.writeInt(seconds.toInt())
                }
            }
            pos += size
        }
    }
}
