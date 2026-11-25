package com.kuzayengineering.video_editor

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer

/**
 * Writes where a video was filmed into an MP4 file, the way phones do: a
 * "©xyz" entry (ISO 6709 text such as "+37.4219-122.0840/") in the movie's
 * user-data box, which galleries such as Google Photos read.
 *
 * The same steps as the app's setMp4Location (lib/engine/mp4_location.dart,
 * tested there on real files): the video and sound data never move. The
 * movie box is rewritten in place when there is room (it is the last box,
 * or followed by free space); otherwise the old one is marked free and the
 * new one goes at the end of the file.
 */
object Mp4Location {
    private const val XYZ = "©xyz"

    fun set(file: File, iso6709: String) {
        RandomAccessFile(file, "rw").use { f ->
            val length = f.length()
            // Top-level boxes: type, position, size.
            val boxes = mutableListOf<Triple<String, Long, Long>>()
            var pos = 0L
            val type = ByteArray(4)
            while (pos + 8 <= length) {
                f.seek(pos)
                var size = f.readInt().toLong() and 0xFFFFFFFFL
                f.readFully(type)
                if (size == 1L) size = f.readLong() else if (size == 0L) size = length - pos
                if (size < 8 || pos + size > length) break
                boxes += Triple(String(type, Charsets.ISO_8859_1), pos, size)
                pos += size
            }
            val i = boxes.indexOfFirst { it.first == "moov" }
            if (i < 0) return
            val (_, moovPos, moovSize) = boxes[i]
            if (moovSize > Int.MAX_VALUE) return
            val moov = ByteArray(moovSize.toInt())
            f.seek(moovPos)
            f.readFully(moov)
            // (A 64-bit size header on the movie box: leave the file alone.)
            if (ByteBuffer.wrap(moov).getInt(0) == 1) return
            val updated = moovWithLocation(moov, iso6709)

            val next = boxes.getOrNull(i + 1)
            if (next == null) {
                // The last box: rewrite it, the file grows.
                f.setLength(moovPos)
                f.seek(moovPos)
                f.write(updated)
                return
            }
            if (next.first == "free") {
                val room = moovSize + next.third - updated.size
                if (room == 0L || room >= 8) {
                    f.seek(moovPos)
                    f.write(updated)
                    if (room >= 8) f.write(box("free", ByteArray((room - 8).toInt())))
                    return
                }
            }
            // No room in place: mark the old movie box free, add the new one
            // at the end (nothing else moves, so every data offset stays right).
            f.seek(moovPos + 4)
            f.write("free".toByteArray(Charsets.ISO_8859_1))
            f.seek(length)
            f.write(updated)
        }
    }

    /** [moov] (a whole "moov" box) with a "©xyz" location in its "udta" box. */
    private fun moovWithLocation(moov: ByteArray, iso6709: String): ByteArray {
        val text = iso6709.toByteArray(Charsets.ISO_8859_1)
        val xyzBody = ByteBuffer.allocate(4 + text.size)
            .putShort(text.size.toShort())
            .putShort(0x15c7.toShort()) // language: English, as phones write it
            .put(text)
            .array()
        val xyz = box(XYZ, xyzBody)

        val out = ByteArrayOutputStream()
        var hadUdta = false
        for ((t, s, e) in children(moov, 8, moov.size)) {
            if (t == "udta") {
                hadUdta = true
                val inner = ByteArrayOutputStream()
                for ((t2, s2, e2) in children(moov, s + 8, e)) {
                    if (t2 != XYZ) inner.write(moov, s2, e2 - s2)
                }
                inner.write(xyz)
                out.write(box("udta", inner.toByteArray()))
            } else {
                out.write(moov, s, e - s)
            }
        }
        if (!hadUdta) out.write(box("udta", xyz))
        return box("moov", out.toByteArray())
    }

    private fun children(d: ByteArray, start: Int, end: Int): List<Triple<String, Int, Int>> {
        val b = ByteBuffer.wrap(d)
        val out = mutableListOf<Triple<String, Int, Int>>()
        var pos = start
        while (pos + 8 <= end) {
            val size = b.getInt(pos).toLong() and 0xFFFFFFFFL
            if (size < 8 || pos + size > end) break
            out += Triple(String(d, pos + 4, 4, Charsets.ISO_8859_1), pos, (pos + size).toInt())
            pos += size.toInt()
        }
        return out
    }

    private fun box(type: String, body: ByteArray): ByteArray =
        ByteBuffer.allocate(8 + body.size)
            .putInt(8 + body.size)
            .put(type.toByteArray(Charsets.ISO_8859_1))
            .put(body)
            .array()
}
