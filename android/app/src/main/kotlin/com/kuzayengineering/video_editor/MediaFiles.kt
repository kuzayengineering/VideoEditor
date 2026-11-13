package com.kuzayengineering.video_editor

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract

/** Finding media files again after they were moved. */
object MediaFiles {
    /** The [sources] that can no longer be opened. */
    fun missing(context: Context, sources: List<String>): List<String> = sources.filter { s ->
        try {
            context.contentResolver.openFileDescriptor(Uri.parse(s), "r")?.close() == null
        } catch (_: Exception) {
            true
        }
    }

    /**
     * The video and sound files in a folder the user chose (a document
     * tree) and its subfolders, as readable addresses with their names.
     * The folder's access is kept (taken when it was picked), so the files
     * stay readable after the app restarts.
     */
    fun list(context: Context, folder: String): List<Map<String, String>> {
        val tree = Uri.parse(folder)
        val out = mutableListOf<Map<String, String>>()
        fun walk(docId: String, depth: Int) {
            if (out.size >= 5000) return
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            val cursor = try {
                context.contentResolver.query(
                    children,
                    arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                        DocumentsContract.Document.COLUMN_MIME_TYPE,
                    ),
                    null, null, null,
                )
            } catch (_: Exception) {
                null
            } ?: return
            val folders = mutableListOf<String>()
            cursor.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0) ?: continue
                    val name = c.getString(1) ?: continue
                    val mime = c.getString(2) ?: ""
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        folders.add(id)
                    } else if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                        out.add(mapOf("source" to uri.toString(), "name" to name))
                    }
                }
            }
            if (depth < 6) for (f in folders) walk(f, depth + 1)
        }
        walk(DocumentsContract.getTreeDocumentId(tree), 0)
        return out
    }
}
