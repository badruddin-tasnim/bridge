package com.link.clipboardsync

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.util.Log
import java.io.File
import java.io.FileNotFoundException

/**
 * Read-only [ContentProvider] that serves the active synced clipboard image
 * from the app's private cache directory so any target app or keyboard
 * (Gboard, Samsung Keyboard, WhatsApp, Telegram, Messages, Notes, Chrome, etc.)
 * can immediately read and paste the `content://` URI from [android.content.ClipboardManager].
 */
class ClipboardImageProvider : ContentProvider() {

    companion object {
        private const val TAG = "ClipboardImageProvider"
        const val AUTHORITY = "com.link.clipboardsync.clipboardprovider"
        private const val DIR_NAME = "shared_clipboard"
        private const val MAX_CACHED_IMAGES = 3
        private val SAFE_FILENAME_REGEX = Regex("^clip_\\d+\\.(png|jpg)$")

        fun saveImageAndGetUri(context: Context, bytes: ByteArray, mimeType: String): Uri? {
            return try {
                val dir = File(context.cacheDir, DIR_NAME)
                if (!dir.exists()) {
                    dir.mkdirs()
                }

                val ext = if (mimeType.contains("png", ignoreCase = true)) "png" else "jpg"
                val fileName = "clip_${System.currentTimeMillis()}.$ext"
                val targetFile = File(dir, fileName)
                targetFile.writeBytes(bytes)

                // Prune older cached clipboard images while keeping the most recent ones
                val files = dir.listFiles()?.sortedByDescending { it.lastModified() } ?: emptyList()
                if (files.size > MAX_CACHED_IMAGES) {
                    for (oldFile in files.drop(MAX_CACHED_IMAGES)) {
                        try { oldFile.delete() } catch (ignored: Exception) {}
                    }
                }

                Uri.Builder()
                    .scheme("content")
                    .authority(AUTHORITY)
                    .appendPath(fileName)
                    .build()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to save clipboard image: ${e.message}", e)
                null
            }
        }
    }

    override fun onCreate(): Boolean = true

    private fun resolveSafeFile(uri: Uri): File? {
        val ctx = context ?: return null
        val fileName = uri.lastPathSegment ?: return null
        if (!SAFE_FILENAME_REGEX.matches(fileName)) {
            return null
        }
        return try {
            val dir = File(ctx.cacheDir, DIR_NAME)
            val file = File(dir, fileName)
            if (file.exists() && file.canonicalPath.startsWith(dir.canonicalPath)) {
                file
            } else {
                null
            }
        } catch (e: Exception) {
            null
        }
    }

    override fun getType(uri: Uri): String? {
        val name = uri.lastPathSegment?.lowercase() ?: return null
        return when {
            name.endsWith(".png") -> "image/png"
            name.endsWith(".jpg") || name.endsWith(".jpeg") -> "image/jpeg"
            else -> "image/*"
        }
    }

    override fun getStreamTypes(uri: Uri, mimeTypeFilter: String): Array<String>? {
        val type = getType(uri) ?: return null
        return if (mimeTypeFilter == "*/*" ||
            mimeTypeFilter.startsWith("image/") ||
            mimeTypeFilter.equals(type, ignoreCase = true)
        ) {
            arrayOf(type)
        } else {
            null
        }
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? {
        val file = resolveSafeFile(uri) ?: return null
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val values = arrayOfNulls<Any>(cols.size)

        for (i in cols.indices) {
            when (cols[i]) {
                OpenableColumns.DISPLAY_NAME -> values[i] = file.name
                OpenableColumns.SIZE -> values[i] = file.length()
            }
        }

        return MatrixCursor(cols, 1).apply {
            addRow(values)
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        if (mode != "r") {
            throw SecurityException("ClipboardImageProvider is read-only")
        }
        val file = resolveSafeFile(uri)
            ?: throw FileNotFoundException("No clipboard image for URI: $uri")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0
}
