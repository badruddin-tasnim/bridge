package com.link.clipboardsync

import android.app.DownloadManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.RandomAccessFile
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

enum class TransferDirection {
    OUTGOING, // Android -> Mac
    INCOMING  // Mac -> Android
}

enum class TransferStatus {
    HASHING,
    WAITING_CONFIRMATION,
    TRANSFERRING,
    PAUSED,
    VERIFYING,
    COMPLETED,
    FAILED,
    CANCELLED;

    val isActive: Boolean
        get() = this == HASHING || this == WAITING_CONFIRMATION || this == TRANSFERRING || this == VERIFYING

    val isFinished: Boolean
        get() = this == COMPLETED || this == FAILED || this == CANCELLED
}

class FileTransferItem(
    val id: String,
    @Volatile var fileName: String,
    @Volatile var fileSize: Long,
    @Volatile var expectedSha256: String = "",
    val direction: TransferDirection,
    val deviceName: String = "Mac",
    val sourceUri: Uri? = null,
    @Volatile var isFolder: Boolean = false,
    @Volatile var tempArchiveFile: File? = null,
    @Volatile var partFile: File? = null,
    @Volatile var destinationFile: File? = null,
    @Volatile var destinationUri: Uri? = null,
    @Volatile var status: TransferStatus = TransferStatus.WAITING_CONFIRMATION,
    @Volatile var errorMessage: String? = null,
    @Volatile var offerHost: String? = null,
    @Volatile var offerPort: Int = 0,
    @Volatile var offerToken: String = "",
    val createdAt: Long = System.currentTimeMillis()
) {
    val isExecutable: Boolean
        get() = if (isFolder) false else BridgeFileTransferManager.isExecutable(fileName)

    @Volatile var bytesTransferred: Long = 0L
    @Volatile var speedBytesPerSec: Double = 0.0
    @Volatile var completedAt: Long = 0L

    val progress: Float
        get() {
            if (fileSize <= 0L) return 0f
            return min(1f, max(0f, bytesTransferred.toFloat() / fileSize.toFloat()))
        }

    val percentageInt: Int
        get() = (progress * 100f).roundToInt()

    val formattedTotalSize: String
        get() = BridgeFileTransferManager.formatBytes(fileSize)

    val formattedProgressSize: String
        get() = "${BridgeFileTransferManager.formatBytes(bytesTransferred)} / ${BridgeFileTransferManager.formatBytes(fileSize)}"

    val formattedSpeed: String
        get() = if (speedBytesPerSec > 0) "${BridgeFileTransferManager.formatBytes(speedBytesPerSec.toLong())}/s" else ""

    val remainingTimeText: String
        get() {
            if (status != TransferStatus.TRANSFERRING) return ""
            val remainingBytes = fileSize - bytesTransferred
            if (remainingBytes <= 0 || speedBytesPerSec <= 10_000.0) return ""
            val seconds = (remainingBytes / speedBytesPerSec).roundToInt()
            return when {
                seconds < 5 -> "A few seconds remaining"
                seconds < 60 -> "About $seconds sec remaining"
                seconds < 3600 -> {
                    val mins = max(1, (seconds + 30) / 60)
                    "About $mins min remaining"
                }
                else -> {
                    val hours = (seconds + 1800) / 3600
                    "About $hours hr remaining"
                }
            }
        }

    val fileExtension: String
        get() = fileName.substringAfterLast('.', "").lowercase()

    val iconResId: Int
        get() {
            if (isFolder) {
                return R.drawable.ic_file_folder
            }
            return when (fileExtension) {
                "pdf" -> R.drawable.ic_file_pdf
                "jpg", "jpeg", "png", "webp", "gif", "heic", "svg", "bmp" -> R.drawable.ic_file_image
                "mp4", "mkv", "mov", "avi", "webm", "m4v" -> R.drawable.ic_file_video
                "mp3", "m4a", "wav", "aac", "flac", "ogg" -> R.drawable.ic_file_audio
                "zip", "tar", "gz", "7z", "rar", "bz2" -> R.drawable.ic_file_archive
                "apk" -> R.drawable.ic_file_apk
                else -> R.drawable.ic_file_doc
            }
        }

    val fileBadgeText: String
        get() {
            if (isFolder) return "ZIP"
            return when (fileExtension) {
                "pdf" -> "PDF"
                "jpg", "jpeg", "png", "webp", "gif", "heic", "svg" -> "IMG"
                "mp4", "mkv", "mov", "avi", "webm" -> "VID"
                "mp3", "m4a", "wav", "aac", "flac", "ogg" -> "AUD"
                "zip", "tar", "gz", "7z", "rar", "bz2" -> "ZIP"
                "doc", "docx", "txt", "md", "csv", "xls", "xlsx", "ppt", "pptx" -> "DOC"
                "apk" -> "APK"
                else -> "FILE"
            }
        }
}

object BridgeFileTransferManager {
    private const val TAG = "BridgeFileTransfer"
    private const val CHUNK_SIZE = 64 * 1024 // 64 KB chunk size for hardware-accelerated AES-GCM framing
    private const val SOCKET_BUFFER_SIZE = 2 * 1024 * 1024 // 2 MB TCP window buffer
    private const val HASH_CHUNK_SIZE = 1024 * 1024 // 1 MB
    private const val SAFETY_FREE_SPACE_BYTES = 50L * 1024L * 1024L // 50 MB
    private const val CHANNEL_ID_FILES = "bridge_file_transfers"
    private const val CHANNEL_ID_TRANSFERS_PROGRESS = "bridge_file_transfers_progress"

    fun isIgnoredMetadata(name: String): Boolean {
        val lower = name.lowercase()
        return lower == ".ds_store" || lower == "thumbs.db" || lower == "desktop.ini" ||
               lower == "__macosx" || lower == ".trashes" || lower == ".spotlight-v100" ||
               lower == ".fseventsd" || lower == ".temporaryitems" || lower == ".apdisk" ||
               name.startsWith("._") || name.startsWith(".~")
    }

    private val EXECUTABLE_EXTENSIONS = setOf(
        "apk", "sh", "command", "app", "dmg", "pkg", "exe", "bat", "cmd", "bin", "jar", "dex", "so", "vbs", "msi"
    )

    fun isExecutable(fileName: String): Boolean {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        return EXECUTABLE_EXTENSIONS.contains(ext)
    }

    internal fun deriveAesKey(token: String): SecretKeySpec {
        val digest = MessageDigest.getInstance("SHA-256")
        val keyBytes = digest.digest((token + ":bridge-file-encryption").toByteArray(Charsets.UTF_8))
        return SecretKeySpec(keyBytes, "AES")
    }

    private fun readFully(input: InputStream, buffer: ByteArray, length: Int): Boolean {
        var total = 0
        while (total < length) {
            val r = input.read(buffer, total, length - total)
            if (r < 0) return false
            total += r
        }
        return true
    }

    @Volatile private var appContext: Context? = null

    interface TransferUiListener {
        fun onTransfersChanged()
    }

    val transfers = CopyOnWriteArrayList<FileTransferItem>()
    private val listeners = CopyOnWriteArrayList<TransferUiListener>()
    private val activeSockets = ConcurrentHashMap<String, Socket>()
    private val pausedIds = ConcurrentHashMap.newKeySet<String>()
    private val cancelledIds = ConcurrentHashMap.newKeySet<String>()

    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val transferExecutor = Executors.newCachedThreadPool()
    private val hashExecutor = Executors.newSingleThreadExecutor()

    fun addListener(l: TransferUiListener) {
        if (!listeners.contains(l)) {
            listeners.add(l)
        }
    }

    fun removeListener(l: TransferUiListener) {
        listeners.remove(l)
    }

    private fun notifyUi() {
        mainHandler.post {
            for (l in listeners) {
                try {
                    l.onTransfersChanged()
                } catch (_: Exception) {}
            }
        }
    }

    private fun sendControlJson(obj: JSONObject) {
        val client = ClipboardSyncManager.networkClient
        val ok = client?.sendRawJson(obj.toString()) ?: false
        Log.d(TAG, "sendControlJson type=${obj.optString("type")}, ok=$ok, isConnected=${client?.isConnected()}")
    }

    // MARK: - Outgoing Files (Android -> Mac)

    fun sendFiles(context: Context, uris: List<Uri>) {
        val appCtx = context.applicationContext
        appContext = appCtx
        val macName = BridgePrefs.macName(appCtx) ?: "Mac"
        Log.d(TAG, "sendFiles called with ${uris.size} URIs to $macName")

        for (uri in uris) {
            try {
                appCtx.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {}

            val meta = resolveUriMetadata(appCtx, uri)
            if (meta == null) {
                Log.w(TAG, "Could not resolve metadata for URI: $uri")
                continue
            }
            val (rawName, size) = meta
            if (size <= 0L) continue

            val cleanName = sanitizeFileName(rawName)
            val id = "tx_" + UUID.randomUUID().toString().replace("-", "").lowercase()
            Log.d(TAG, "Enqueueing outgoing transfer '$cleanName' ($size bytes, isExecutable=${isExecutable(cleanName)}) with id: $id")

            val item = FileTransferItem(
                id = id,
                fileName = cleanName,
                fileSize = size,
                direction = TransferDirection.OUTGOING,
                deviceName = macName,
                sourceUri = uri,
                status = TransferStatus.HASHING
            )

            transfers.add(0, item)
            notifyUi()

            hashExecutor.execute {
                Log.d(TAG, "Starting hash computation for $cleanName (uri: $uri)")
                val sha256 = computeUriSha256(appCtx, uri) {
                    cancelledIds.contains(id) || item.status == TransferStatus.CANCELLED
                }
                Log.d(TAG, "Hash computed for $cleanName: $sha256")
                if (sha256 == null) {
                    if (!cancelledIds.contains(id) && item.status != TransferStatus.CANCELLED) {
                        item.status = TransferStatus.FAILED
                        item.errorMessage = "Could not read file"
                        notifyUi()
                    }
                    return@execute
                }

                item.expectedSha256 = sha256
                item.status = TransferStatus.WAITING_CONFIRMATION
                notifyUi()

                val req = JSONObject().apply {
                    put("type", "file_request")
                    put("id", item.id)
                    put("name", item.fileName)
                    put("size", item.fileSize)
                    put("sha256", item.expectedSha256)
                    put("isFolder", false)
                }
                Log.d(TAG, "Sending file_request to Mac: $req")
                sendControlJson(req)
            }
        }
    }

    fun sendFolder(context: Context, treeUri: Uri) {
        val appCtx = context.applicationContext
        appContext = appCtx
        val macName = BridgePrefs.macName(appCtx) ?: "Mac"

        try {
            appCtx.contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (_: Exception) {}

        val docTree = DocumentFile.fromTreeUri(appCtx, treeUri) ?: return
        val rawName = docTree.name ?: "Folder"
        val cleanName = sanitizeFileName(rawName)
        val id = "tx_" + UUID.randomUUID().toString().replace("-", "").lowercase()
        Log.d(TAG, "Enqueueing outgoing folder transfer '$cleanName' with id: $id")

        val item = FileTransferItem(
            id = id,
            fileName = cleanName,
            fileSize = 0L,
            direction = TransferDirection.OUTGOING,
            deviceName = macName,
            sourceUri = treeUri,
            isFolder = true,
            status = TransferStatus.HASHING
        )

        transfers.add(0, item)
        notifyUi()

        hashExecutor.execute {
            val tempZipFile = File(appCtx.cacheDir, "bridge_pkg_${id}.zip")
            if (tempZipFile.exists()) tempZipFile.delete()

            val success = packageDocumentTreeToZip(appCtx, docTree, tempZipFile) {
                cancelledIds.contains(id) || item.status == TransferStatus.CANCELLED
            }

            if (!success || !tempZipFile.exists() || tempZipFile.length() <= 0L) {
                tempZipFile.delete()
                if (!cancelledIds.contains(id) && item.status != TransferStatus.CANCELLED) {
                    item.status = TransferStatus.FAILED
                    item.errorMessage = "Could not package folder"
                    notifyUi()
                }
                return@execute
            }

            val sha256 = computeFileSha256(tempZipFile)
            if (sha256 == null) {
                tempZipFile.delete()
                if (!cancelledIds.contains(id) && item.status != TransferStatus.CANCELLED) {
                    item.status = TransferStatus.FAILED
                    item.errorMessage = "Could not hash folder"
                    notifyUi()
                }
                return@execute
            }

            item.tempArchiveFile = tempZipFile
            item.fileSize = tempZipFile.length()
            item.expectedSha256 = sha256
            item.status = TransferStatus.WAITING_CONFIRMATION
            notifyUi()

            val req = JSONObject().apply {
                put("type", "file_request")
                put("id", item.id)
                put("name", item.fileName)
                put("size", item.fileSize)
                put("sha256", item.expectedSha256)
                put("isFolder", true)
            }
            Log.d(TAG, "Sending folder file_request to Mac: $req")
            sendControlJson(req)
        }
    }

    private fun packageDocumentTreeToZip(
        context: Context,
        rootDir: DocumentFile,
        outputZip: File,
        shouldAbort: () -> Boolean
    ): Boolean {
        return try {
            val rootName = sanitizeFileName(rootDir.name ?: "Folder")
            // Use 128KB buffer and Deflater.BEST_SPEED (level 1) for near-instant packaging
            ZipOutputStream(BufferedOutputStream(FileOutputStream(outputZip), 131072)).use { zos ->
                zos.setLevel(Deflater.BEST_SPEED)
                val queue = ArrayDeque<Pair<DocumentFile, String>>()
                queue.add(Pair(rootDir, rootName))
                val buffer = ByteArray(131072)

                while (!queue.isEmpty()) {
                    if (shouldAbort()) return false
                    val (currentDoc, currentPath) = queue.removeFirst()
                    val files = currentDoc.listFiles()
                    for (file in files) {
                        if (shouldAbort()) return false
                        val fileName = file.name ?: continue
                        if (isIgnoredMetadata(fileName)) continue

                        val entryName = "$currentPath/$fileName"
                        if (file.isDirectory) {
                            zos.putNextEntry(ZipEntry("$entryName/"))
                            zos.closeEntry()
                            queue.add(Pair(file, entryName))
                        } else if (file.isFile) {
                            zos.putNextEntry(ZipEntry(entryName))
                            context.contentResolver.openInputStream(file.uri)?.use { inStream ->
                                inStream.copyTo(zos, 131072)
                            }
                            zos.closeEntry()
                        }
                    }
                }
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "Error packaging folder to zip: ${e.message}")
            false
        }
    }

    private fun startOutgoingStream(
        context: Context,
        item: FileTransferItem,
        host: String,
        port: Int,
        token: String,
        offset: Long
    ) {
        transferExecutor.execute {
            pausedIds.remove(item.id)
            cancelledIds.remove(item.id)
            var sock: Socket? = null
            var input: InputStream? = null
            try {
                val rawInput: InputStream = if (item.isFolder && item.tempArchiveFile != null) {
                    FileInputStream(item.tempArchiveFile!!)
                } else {
                    val uri = item.sourceUri ?: throw IllegalStateException("Missing file URI")
                    if (uri.scheme == "file") {
                        val path = uri.path ?: ""
                        var f = File(path)
                        if (!f.exists()) {
                            f = File(path.replaceFirst("^/sdcard", "/storage/emulated/0"))
                        }
                        FileInputStream(f)
                    } else {
                        context.applicationContext.contentResolver.openInputStream(uri)
                            ?: throw IllegalStateException("Cannot open input stream for $uri")
                    }
                }
                input = BufferedInputStream(rawInput, CHUNK_SIZE)

                val s = Socket()
                s.tcpNoDelay = true
                s.keepAlive = true
                s.sendBufferSize = SOCKET_BUFFER_SIZE
                s.receiveBufferSize = SOCKET_BUFFER_SIZE
                s.connect(InetSocketAddress(host, port), 5000)
                s.soTimeout = 20000
                sock = s
                activeSockets[item.id] = s

                val header = JSONObject().apply {
                    put("token", token)
                    put("id", item.id)
                    put("offset", offset)
                }.toString() + "\n"

                val out = BufferedOutputStream(s.getOutputStream(), CHUNK_SIZE)
                out.write(header.toByteArray(Charsets.UTF_8))
                out.flush()

                if (offset > 0L) {
                    skipFully(input, offset)
                }

                item.bytesTransferred = offset
                item.status = TransferStatus.TRANSFERRING
                notifyUi()
                updateProgressNotification(context, item)

                val aesKey = deriveAesKey(token)
                val secureRandom = SecureRandom()
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                val buf = ByteArray(CHUNK_SIZE)
                var currentBytes = offset
                var lastSpeedTime = System.currentTimeMillis()
                var bytesSinceLastSpeed = 0L
                var lastUiUpdateTime = 0L
                var lastNotifUpdateTime = 0L

                while (currentBytes < item.fileSize) {
                    if (pausedIds.contains(item.id) || cancelledIds.contains(item.id)) {
                        break
                    }
                    val read = input.read(buf)
                    if (read <= 0) break

                    val iv = ByteArray(12)
                    secureRandom.nextBytes(iv)
                    cipher.init(Cipher.ENCRYPT_MODE, aesKey, GCMParameterSpec(128, iv))
                    val ciphertextWithTag = cipher.doFinal(buf, 0, read)

                    val combinedLen = 12 + ciphertextWithTag.size
                    out.write((combinedLen ushr 24).toByte().toInt())
                    out.write((combinedLen ushr 16).toByte().toInt())
                    out.write((combinedLen ushr 8).toByte().toInt())
                    out.write(combinedLen.toByte().toInt())
                    out.write(iv)
                    out.write(ciphertextWithTag)

                    currentBytes += read
                    bytesSinceLastSpeed += read
                    item.bytesTransferred = currentBytes

                    val now = System.currentTimeMillis()
                    val elapsedSec = (now - lastSpeedTime) / 1000.0
                    if (elapsedSec >= 0.25) {
                        item.speedBytesPerSec = bytesSinceLastSpeed / elapsedSec
                        lastSpeedTime = now
                        bytesSinceLastSpeed = 0L
                    }
                    if (now - lastUiUpdateTime >= 150) {
                        lastUiUpdateTime = now
                        notifyUi()
                    }
                    if (now - lastNotifUpdateTime >= 500) {
                        lastNotifUpdateTime = now
                        updateProgressNotification(context, item)
                    }
                }
                out.flush()

                dismissProgressNotification(context, item.id)

                if (cancelledIds.contains(item.id)) {
                    item.status = TransferStatus.CANCELLED
                    item.speedBytesPerSec = 0.0
                    notifyUi()
                } else if (pausedIds.contains(item.id)) {
                    item.status = TransferStatus.PAUSED
                    item.speedBytesPerSec = 0.0
                    notifyUi()
                } else if (currentBytes >= item.fileSize) {
                    item.bytesTransferred = item.fileSize
                    item.speedBytesPerSec = 0.0
                    item.status = TransferStatus.VERIFYING
                    notifyUi()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Outgoing transfer interrupted: ${e.message}")
                if (cancelledIds.contains(item.id)) {
                    item.status = TransferStatus.CANCELLED
                } else if (pausedIds.contains(item.id) || item.status == TransferStatus.TRANSFERRING) {
                    item.status = TransferStatus.PAUSED
                } else {
                    item.status = TransferStatus.FAILED
                    item.errorMessage = e.message ?: "Connection failed"
                }
                item.speedBytesPerSec = 0.0
                notifyUi()
            } finally {
                dismissProgressNotification(context, item.id)
                try { input?.close() } catch (_: Exception) {}
                try { sock?.close() } catch (_: Exception) {}
                activeSockets.remove(item.id)
                if (item.isFolder && (item.status.isFinished || cancelledIds.contains(item.id))) {
                    item.tempArchiveFile?.delete()
                    item.tempArchiveFile = null
                }
            }
        }
    }

    // MARK: - Incoming Files (Mac -> Android)

    fun handleControlMessage(context: Context, jsonObj: JSONObject, macHost: String?) {
        val appCtx = context.applicationContext
        appContext = appCtx
        val type = jsonObj.optString("type")
        val id = jsonObj.optString("id")
        if (id.isBlank()) return
        Log.d(TAG, "handleControlMessage: type='$type', id='$id'")

        val resolvedHost = macHost ?: BridgePrefs.host(appCtx)

        when (type) {
            "file_offer" -> {
                val rawName = jsonObj.optString("name", "file")
                val size = jsonObj.optLong("size", 0L)
                val sha256 = jsonObj.optString("sha256", "")
                val port = jsonObj.optInt("port", 0)
                val token = jsonObj.optString("token", "")
                val isResume = jsonObj.optBoolean("resume", false)
                val isFolder = jsonObj.optBoolean("isFolder", false)

                if (size <= 0L || port <= 0 || token.isBlank() || resolvedHost.isNullOrBlank()) return

                val cleanName = sanitizeFileName(rawName)
                val targetFileName = if (isFolder && !cleanName.endsWith(".zip", ignoreCase = true)) "$cleanName.zip" else cleanName
                val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                if (!downloadsDir.exists()) {
                    downloadsDir.mkdirs()
                }

                if (!hasEnoughDiskSpace(downloadsDir, size)) {
                    val rej = JSONObject().apply {
                        put("type", "file_reject")
                        put("id", id)
                        put("reason", "insufficient_space")
                    }
                    sendControlJson(rej)
                    return
                }

                val existing = transfers.firstOrNull { it.id == id }
                val item: FileTransferItem
                if (existing != null) {
                    existing.offerHost = resolvedHost
                    existing.offerPort = port
                    existing.offerToken = token
                    existing.isFolder = isFolder
                    existing.fileName = targetFileName
                    item = existing
                } else {
                    val partDir = File(appCtx.cacheDir, "transfers").apply { if (!exists()) mkdirs() }
                    val partFile = File(partDir, "$id.part")
                    item = FileTransferItem(
                        id = id,
                        fileName = targetFileName,
                        fileSize = size,
                        expectedSha256 = sha256,
                        direction = TransferDirection.INCOMING,
                        deviceName = BridgePrefs.macName(appCtx) ?: "Mac",
                        partFile = partFile,
                        isFolder = isFolder,
                        status = TransferStatus.WAITING_CONFIRMATION,
                        offerHost = resolvedHost,
                        offerPort = port,
                        offerToken = token
                    )
                    transfers.add(0, item)
                }
                notifyUi()

                val shouldAutoAccept = (isResume || BridgePrefs.isAutoAcceptFilesEnabled(appCtx)) && (isFolder || !isExecutable(cleanName))
                if (shouldAutoAccept) {
                    acceptIncomingFile(appCtx, item.id)
                } else {
                    postIncomingPromptNotification(appCtx, item)
                }
            }

            "file_accept" -> {
                val port = jsonObj.optInt("port", 0)
                val token = jsonObj.optString("token", "")
                val offset = jsonObj.optLong("offset", 0L)
                val item = transfers.firstOrNull { it.id == id } ?: return
                if (port <= 0 || token.isBlank() || resolvedHost.isNullOrBlank()) return

                startOutgoingStream(appCtx, item, resolvedHost, port, token, offset)
            }

            "file_reject" -> {
                val reason = jsonObj.optString("reason", "Declined")
                val item = transfers.firstOrNull { it.id == id } ?: return
                item.status = TransferStatus.FAILED
                item.errorMessage = if (reason == "insufficient_space") "Insufficient disk space on Mac" else "Declined by Mac"
                item.speedBytesPerSec = 0.0
                notifyUi()
            }

            "file_pause" -> {
                pauseTransfer(id, notifyPeer = false)
            }

            "file_resume" -> {
                resumeTransfer(appCtx, id, notifyPeer = false)
            }

            "file_cancel" -> {
                cancelTransfer(id, notifyPeer = false)
            }

            "file_complete" -> {
                val item = transfers.firstOrNull { it.id == id } ?: return
                activeSockets.remove(id)?.let { try { it.close() } catch (_: Exception) {} }
                item.bytesTransferred = item.fileSize
                item.speedBytesPerSec = 0.0
                item.status = TransferStatus.COMPLETED
                notifyUi()
            }

            "file_error" -> {
                val reason = jsonObj.optString("reason", "Transfer failed")
                val item = transfers.firstOrNull { it.id == id } ?: return
                activeSockets.remove(id)?.let { try { it.close() } catch (_: Exception) {} }
                item.speedBytesPerSec = 0.0
                item.status = TransferStatus.FAILED
                item.errorMessage = reason
                notifyUi()
            }
        }
    }

    fun acceptIncomingFile(context: Context, id: String) {
        val appCtx = context.applicationContext
        appContext = appCtx
        dismissPromptNotification(appCtx, id)
        val item = transfers.firstOrNull { it.id == id } ?: return
        val host = item.offerHost ?: BridgePrefs.host(appCtx) ?: return
        val port = item.offerPort
        val token = item.offerToken
        if (port <= 0 || token.isBlank()) return

        transferExecutor.execute {
            pausedIds.remove(item.id)
            cancelledIds.remove(item.id)
            var sock: Socket? = null
            var raf: RandomAccessFile? = null
            try {
                val partDir = File(appCtx.cacheDir, "transfers").apply { if (!exists()) mkdirs() }
                val partFile = item.partFile ?: File(partDir, "${item.id}.part").also {
                    item.partFile = it
                }

                var offset = 0L
                if (partFile.exists()) {
                    val len = partFile.length()
                    if (len in 1 until item.fileSize) {
                        offset = len
                    } else {
                        partFile.delete()
                    }
                }

                val s = Socket()
                s.tcpNoDelay = true
                s.keepAlive = true
                s.sendBufferSize = SOCKET_BUFFER_SIZE
                s.receiveBufferSize = SOCKET_BUFFER_SIZE
                s.connect(InetSocketAddress(host, port), 5000)
                s.soTimeout = 20000
                sock = s
                activeSockets[item.id] = s

                val header = JSONObject().apply {
                    put("token", token)
                    put("id", item.id)
                    put("offset", offset)
                }.toString() + "\n"

                val out = s.getOutputStream()
                out.write(header.toByteArray(Charsets.UTF_8))
                out.flush()

                raf = RandomAccessFile(partFile, "rw")
                if (offset > 0L) {
                    raf.seek(offset)
                }

                item.bytesTransferred = offset
                item.status = TransferStatus.TRANSFERRING
                notifyUi()
                updateProgressNotification(context, item)

                val input = java.io.BufferedInputStream(s.getInputStream(), CHUNK_SIZE)
                val aesKey = deriveAesKey(token)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                val headerBuf = ByteArray(4)
                var currentBytes = offset
                var lastSpeedTime = System.currentTimeMillis()
                var bytesSinceLastSpeed = 0L
                var lastUiUpdateTime = 0L
                var lastNotifUpdateTime = 0L

                while (currentBytes < item.fileSize) {
                    if (pausedIds.contains(item.id) || cancelledIds.contains(item.id)) {
                        break
                    }

                    if (!readFully(input, headerBuf, 4)) break
                    val frameLen = ((headerBuf[0].toInt() and 0xFF) shl 24) or
                                   ((headerBuf[1].toInt() and 0xFF) shl 16) or
                                   ((headerBuf[2].toInt() and 0xFF) shl 8) or
                                   (headerBuf[3].toInt() and 0xFF)

                    if (frameLen <= 28 || frameLen > (CHUNK_SIZE + 2048)) {
                        throw SecurityException("Invalid encrypted frame length: $frameLen")
                    }

                    val framePayload = ByteArray(frameLen)
                    if (!readFully(input, framePayload, frameLen)) {
                        throw java.io.EOFException("Incomplete encrypted frame received")
                    }

                    val spec = GCMParameterSpec(128, framePayload, 0, 12)
                    cipher.init(Cipher.DECRYPT_MODE, aesKey, spec)
                    val plaintext = cipher.doFinal(framePayload, 12, frameLen - 12)

                    if (currentBytes + plaintext.size > item.fileSize) {
                        throw SecurityException("Received bytes exceeded declared file size")
                    }

                    raf.write(plaintext)
                    currentBytes += plaintext.size
                    bytesSinceLastSpeed += plaintext.size
                    item.bytesTransferred = currentBytes

                    val now = System.currentTimeMillis()
                    val elapsedSec = (now - lastSpeedTime) / 1000.0
                    if (elapsedSec >= 0.25) {
                        item.speedBytesPerSec = bytesSinceLastSpeed / elapsedSec
                        lastSpeedTime = now
                        bytesSinceLastSpeed = 0L
                    }
                    if (now - lastUiUpdateTime >= 150) {
                        lastUiUpdateTime = now
                        notifyUi()
                    }
                    if (now - lastNotifUpdateTime >= 500) {
                        lastNotifUpdateTime = now
                        updateProgressNotification(context, item)
                    }
                }

                dismissProgressNotification(context, item.id)

                try { raf.close() } catch (_: Exception) {}
                raf = null
                try { s.close() } catch (_: Exception) {}
                sock = null
                activeSockets.remove(item.id)

                if (cancelledIds.contains(item.id)) {
                    partFile.delete()
                    item.status = TransferStatus.CANCELLED
                    item.speedBytesPerSec = 0.0
                    notifyUi()
                    return@execute
                }

                if (pausedIds.contains(item.id) || currentBytes < item.fileSize) {
                    item.status = TransferStatus.PAUSED
                    item.speedBytesPerSec = 0.0
                    notifyUi()
                    return@execute
                }

                // Completed streaming; verify SHA-256 checksum
                item.bytesTransferred = item.fileSize
                item.speedBytesPerSec = 0.0
                item.status = TransferStatus.VERIFYING
                notifyUi()

                if (item.expectedSha256.isNotBlank()) {
                    val computedHash = computeFileSha256(partFile)
                    if (computedHash == null || !computedHash.equals(item.expectedSha256, ignoreCase = true)) {
                        partFile.delete()
                        item.status = TransferStatus.FAILED
                        item.errorMessage = "SHA-256 verification failed"
                        notifyUi()
                        sendControlJson(JSONObject().apply {
                            put("type", "file_error")
                            put("id", item.id)
                            put("reason", "SHA-256 verification failed")
                        })
                        return@execute
                    }
                }

                val finalName = if (item.isFolder && !item.fileName.endsWith(".zip", ignoreCase = true)) {
                    "${item.fileName}.zip"
                } else {
                    item.fileName
                }
                item.fileName = finalName

                val customUriStr = BridgePrefs.getCustomSaveTreeUri(appCtx)
                var finalFile: File? = null
                var finalDocUri: Uri? = null

                if (!customUriStr.isNullOrBlank()) {
                    try {
                        val treeUri = Uri.parse(customUriStr)
                        val pickedDir = DocumentFile.fromTreeUri(appCtx, treeUri)
                        if (pickedDir != null && pickedDir.canWrite()) {
                            val ext = File(item.fileName).extension.lowercase()
                            val mime = if (item.isFolder || ext == "zip") "application/zip" else (MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream")
                            val targetDoc = pickedDir.createFile(mime, item.fileName)
                            if (targetDoc != null) {
                                appCtx.contentResolver.openOutputStream(targetDoc.uri)?.use { outStream ->
                                    partFile.inputStream().use { inStream ->
                                        inStream.copyTo(outStream)
                                    }
                                }
                                partFile.delete()
                                finalDocUri = targetDoc.uri
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed saving to custom directory: ${e.message}, falling back to Downloads")
                    }
                }

                if (finalDocUri == null) {
                    val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                    if (!downloadsDir.exists()) downloadsDir.mkdirs()
                    val dest = uniqueDestinationFile(downloadsDir, item.fileName)
                    if (!partFile.renameTo(dest)) {
                        partFile.copyTo(dest, overwrite = true)
                        partFile.delete()
                    }
                    finalFile = dest
                    MediaScannerConnection.scanFile(
                        appCtx,
                        arrayOf(dest.absolutePath),
                        null,
                        null
                    )
                }

                item.destinationFile = finalFile
                item.destinationUri = finalDocUri
                item.completedAt = System.currentTimeMillis()
                item.status = TransferStatus.COMPLETED
                notifyUi()

                sendControlJson(JSONObject().apply {
                    put("type", "file_complete")
                    put("id", item.id)
                })

                val locationName = if (finalDocUri != null) {
                    BridgePrefs.getCustomSaveDisplayName(appCtx) ?: "Custom Folder"
                } else {
                    "Downloads"
                }
                postFileSavedNotification(appCtx, item.fileName, item.deviceName, locationName, item.isFolder)
            } catch (e: Exception) {
                Log.w(TAG, "Incoming transfer interrupted: ${e.message}")
                if (cancelledIds.contains(item.id)) {
                    item.partFile?.delete()
                    item.status = TransferStatus.CANCELLED
                } else if (pausedIds.contains(item.id) || item.status == TransferStatus.TRANSFERRING) {
                    item.status = TransferStatus.PAUSED
                } else {
                    item.status = TransferStatus.FAILED
                    item.errorMessage = e.message ?: "Transfer failed"
                }
                item.speedBytesPerSec = 0.0
                notifyUi()
            } finally {
                dismissProgressNotification(context, item.id)
                try { raf?.close() } catch (_: Exception) {}
                try { sock?.close() } catch (_: Exception) {}
                activeSockets.remove(item.id)
            }
        }
    }

    // MARK: - Pause / Resume / Cancel

    fun pauseTransfer(id: String, notifyPeer: Boolean = true) {
        dismissProgressNotification(appContext, id)
        val item = transfers.firstOrNull { it.id == id } ?: return
        pausedIds.add(id)
        activeSockets.remove(id)?.let {
            try { it.close() } catch (_: Exception) {}
        }
        item.status = TransferStatus.PAUSED
        item.speedBytesPerSec = 0.0
        notifyUi()

        if (notifyPeer) {
            sendControlJson(JSONObject().apply {
                put("type", "file_pause")
                put("id", id)
            })
        }
    }

    fun resumeTransfer(context: Context, id: String, notifyPeer: Boolean = true) {
        val item = transfers.firstOrNull { it.id == id } ?: return
        pausedIds.remove(id)
        cancelledIds.remove(id)
        item.status = TransferStatus.WAITING_CONFIRMATION
        item.speedBytesPerSec = 0.0
        notifyUi()

        if (item.direction == TransferDirection.OUTGOING) {
            val req = JSONObject().apply {
                put("type", "file_request")
                put("id", item.id)
                put("name", item.fileName)
                put("size", item.fileSize)
                put("sha256", item.expectedSha256)
                put("isFolder", item.isFolder)
            }
            sendControlJson(req)
        } else {
            if (notifyPeer) {
                sendControlJson(JSONObject().apply {
                    put("type", "file_resume")
                    put("id", id)
                })
            } else {
                acceptIncomingFile(context, id)
            }
        }
    }

    fun cancelTransfer(id: String, notifyPeer: Boolean = true) {
        dismissPromptNotification(null, id)
        dismissProgressNotification(appContext, id)
        val item = transfers.firstOrNull { it.id == id } ?: return
        cancelledIds.add(id)
        activeSockets.remove(id)?.let {
            try { it.close() } catch (_: Exception) {}
        }
        item.partFile?.let {
            try { if (it.exists()) it.delete() } catch (_: Exception) {}
        }
        item.tempArchiveFile?.let {
            try { if (it.exists()) it.delete() } catch (_: Exception) {}
            item.tempArchiveFile = null
        }
        item.status = TransferStatus.CANCELLED
        item.speedBytesPerSec = 0.0
        notifyUi()

        if (notifyPeer) {
            sendControlJson(JSONObject().apply {
                put("type", "file_cancel")
                put("id", id)
            })
        }
    }

    fun clearCompletedTransfers() {
        transfers.removeAll { it.status == TransferStatus.COMPLETED }
        notifyUi()
    }

    fun retryTransfer(context: Context, id: String) {
        val item = transfers.firstOrNull { it.id == id } ?: return
        item.status = TransferStatus.WAITING_CONFIRMATION
        item.errorMessage = null
        item.bytesTransferred = 0L
        item.speedBytesPerSec = 0.0
        notifyUi()

        if (item.direction == TransferDirection.OUTGOING && item.sourceUri != null) {
            val uri = item.sourceUri
            val isFolder = item.isFolder
            transfers.remove(item)
            if (isFolder) {
                sendFolder(context, uri)
            } else {
                sendFiles(context, listOf(uri))
            }
        } else {
            sendControlJson(JSONObject().apply {
                put("type", "file_resume")
                put("id", item.id)
            })
        }
    }

    fun dismissTransfer(id: String) {
        dismissPromptNotification(null, id)
        dismissProgressNotification(appContext, id)
        cancelledIds.add(id)
        activeSockets.remove(id)?.let { try { it.close() } catch (_: Exception) {} }
        val item = transfers.firstOrNull { it.id == id }
        item?.partFile?.let { try { if (it.exists()) it.delete() } catch (_: Exception) {} }
        item?.tempArchiveFile?.let { try { if (it.exists()) it.delete() } catch (_: Exception) {} }
        transfers.removeAll { it.id == id }
        notifyUi()
    }

    fun openTransferredFile(context: Context, item: FileTransferItem) {
        try {
            if (item.isFolder) {
                val destFile = item.destinationFile
                if (destFile != null && destFile.exists()) {
                    try {
                        val uri = FileProvider.getUriForFile(
                            context,
                            "${context.packageName}.fileprovider",
                            destFile
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/zip")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        context.startActivity(Intent.createChooser(intent, item.fileName).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        })
                        return
                    } catch (_: Exception) {}
                    try {
                        val dlIntent = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        context.startActivity(dlIntent)
                        return
                    } catch (_: Exception) {}
                } else if (item.destinationUri != null) {
                    try {
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(item.destinationUri, "application/zip")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        context.startActivity(Intent.createChooser(intent, item.fileName).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        })
                        return
                    } catch (_: Exception) {}
                }
            }

            val uri: Uri
            val mimeType: String
            val destFile = item.destinationFile
            val destUri = item.destinationUri
            if (destUri != null) {
                uri = destUri
                val ext = File(item.fileName).extension.lowercase()
                mimeType = context.contentResolver.getType(uri)
                    ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
                    ?: "*/*"
            } else if (destFile != null && destFile.exists()) {
                uri = FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    destFile
                )
                val ext = destFile.extension.lowercase()
                mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
            } else if (item.sourceUri != null) {
                uri = item.sourceUri
                mimeType = context.contentResolver.getType(uri) ?: "*/*"
            } else {
                return
            }

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(Intent.createChooser(intent, item.fileName).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
        } catch (e: Exception) {
            Log.w(TAG, "Could not open file: ${e.message}")
        }
    }

    // MARK: - Helpers

    private fun resolveUriMetadata(context: Context, uri: Uri): Pair<String, Long>? {
        var displayName = "file"
        var size = -1L
        try {
            if (uri.scheme == "file") {
                val path = uri.path ?: ""
                var f = File(path)
                if (!f.exists()) {
                    f = File(path.replaceFirst("^/sdcard", "/storage/emulated/0"))
                }
                if (f.exists()) {
                    return Pair(f.name, f.length())
                }
            }
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIdx >= 0 && !cursor.isNull(nameIdx)) {
                        displayName = cursor.getString(nameIdx)
                    }
                    if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) {
                        size = cursor.getLong(sizeIdx)
                    }
                }
            }
            if (size <= 0L) {
                context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { afd ->
                    size = afd.length
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to resolve URI metadata: ${e.message}")
            return null
        }
        return if (size > 0L) Pair(displayName, size) else null
    }

    private fun computeUriSha256(
        context: Context,
        uri: Uri,
        shouldAbort: () -> Boolean
    ): String? {
        if (uri.scheme == "file") {
            val path = uri.path ?: ""
            var f = File(path)
            if (!f.exists()) {
                f = File(path.replaceFirst("^/sdcard", "/storage/emulated/0"))
            }
            if (f.exists()) {
                return computeFileSha256(f)
            }
        }
        return try {
            val md = MessageDigest.getInstance("SHA-256")
            val pfd = context.contentResolver.openFileDescriptor(uri, "r")
            val fileSize = pfd?.statSize ?: -1L
            pfd?.close()

            // For large files (> 500 MB), use sparse sampling identical to Mac app
            if (fileSize > 500L * 1024L * 1024L) {
                val sampleSize = 4 * 1024 * 1024
                md.update("SPARSE_V1_$fileSize".toByteArray(Charsets.UTF_8))
                context.contentResolver.openInputStream(uri)?.use { input ->
                    val sampleBuf = ByteArray(sampleSize)

                    // Sample 1: First 4MB
                    var read1 = 0
                    while (read1 < sampleSize) {
                        val r = input.read(sampleBuf, read1, sampleSize - read1)
                        if (r <= 0) break
                        read1 += r
                    }
                    if (read1 > 0) md.update(sampleBuf, 0, read1)
                    if (shouldAbort()) return null

                    // Sample 2: Middle 4MB
                    val midOffset = max(0L, (fileSize / 2L) - (sampleSize / 2L))
                    val skipToMid = midOffset - read1
                    if (skipToMid > 0L) skipFully(input, skipToMid)
                    var read2 = 0
                    while (read2 < sampleSize) {
                        val r = input.read(sampleBuf, read2, sampleSize - read2)
                        if (r <= 0) break
                        read2 += r
                    }
                    if (read2 > 0) md.update(sampleBuf, 0, read2)
                    if (shouldAbort()) return null

                    // Sample 3: Last 4MB
                    val tailOffset = max(0L, fileSize - sampleSize)
                    val skipToTail = tailOffset - (midOffset + read2)
                    if (skipToTail > 0L) skipFully(input, skipToTail)
                    var read3 = 0
                    while (read3 < sampleSize) {
                        val r = input.read(sampleBuf, read3, sampleSize - read3)
                        if (r <= 0) break
                        read3 += r
                    }
                    if (read3 > 0) md.update(sampleBuf, 0, read3)
                } ?: return null
                return md.digest().joinToString("") { "%02x".format(it) }
            }

            context.contentResolver.openInputStream(uri)?.use { input ->
                val buf = ByteArray(HASH_CHUNK_SIZE)
                while (true) {
                    if (shouldAbort()) return null
                    val read = input.read(buf)
                    if (read <= 0) break
                    md.update(buf, 0, read)
                }
            } ?: return null
            md.digest().joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            Log.w(TAG, "computeUriSha256 failed for $uri: ${e.message}")
            null
        }
    }

    private fun computeFileSha256(file: File): String? {
        return try {
            val md = MessageDigest.getInstance("SHA-256")
            val fileSize = file.length()

            // For large files (> 500 MB), use sparse sampling identical to Mac app
            if (fileSize > 500L * 1024L * 1024L) {
                val sampleSize = 4 * 1024 * 1024
                md.update("SPARSE_V1_$fileSize".toByteArray(Charsets.UTF_8))
                RandomAccessFile(file, "r").use { raf ->
                    val sampleBuf = ByteArray(sampleSize)

                    // Sample 1: Head
                    raf.seek(0L)
                    val r1 = raf.read(sampleBuf)
                    if (r1 > 0) md.update(sampleBuf, 0, r1)

                    // Sample 2: Mid
                    val midOffset = max(0L, (fileSize / 2L) - (sampleSize / 2L))
                    raf.seek(midOffset)
                    val r2 = raf.read(sampleBuf)
                    if (r2 > 0) md.update(sampleBuf, 0, r2)

                    // Sample 3: Tail
                    val tailOffset = max(0L, fileSize - sampleSize)
                    raf.seek(tailOffset)
                    val r3 = raf.read(sampleBuf)
                    if (r3 > 0) md.update(sampleBuf, 0, r3)
                }
                return md.digest().joinToString("") { "%02x".format(it) }
            }

            FileInputStream(file).use { input ->
                val buf = ByteArray(HASH_CHUNK_SIZE)
                while (true) {
                    val read = input.read(buf)
                    if (read <= 0) break
                    md.update(buf, 0, read)
                }
            }
            md.digest().joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            Log.w(TAG, "computeFileSha256 failed for ${file.absolutePath}: ${e.message}")
            null
        }
    }

    private fun skipFully(input: InputStream, bytesToSkip: Long) {
        var remaining = bytesToSkip
        val scratch = ByteArray(64 * 1024)
        while (remaining > 0L) {
            val skipped = input.skip(remaining)
            if (skipped > 0L) {
                remaining -= skipped
            } else {
                val toRead = min(remaining, scratch.size.toLong()).toInt()
                val read = input.read(scratch, 0, toRead)
                if (read <= 0) break
                remaining -= read
            }
        }
    }

    internal fun sanitizeFileName(raw: String): String {
        val base = File(raw).name
            .replace("\u0000", "")
            .replace("/", "_")
            .replace("\\", "_")
            .trim()
        if (base.isEmpty() || base == "." || base == "..") {
            return "TransferredFile"
        }
        return if (base.startsWith(".")) "_" + base.removePrefix(".") else base
    }

    private fun uniqueDestinationFile(dir: File, fileName: String): File {
        var candidate = File(dir, fileName)
        if (!candidate.exists()) return candidate

        val dotIdx = fileName.lastIndexOf('.')
        val stem = if (dotIdx > 0) fileName.substring(0, dotIdx) else fileName
        val ext = if (dotIdx > 0) fileName.substring(dotIdx) else ""
        var counter = 1
        while (candidate.exists()) {
            candidate = File(dir, "$stem ($counter)$ext")
            counter++
        }
        return candidate
    }

    private fun hasEnoughDiskSpace(dir: File, requiredBytes: Long): Boolean {
        return try {
            val stat = StatFs(dir.absolutePath)
            stat.availableBytes > (requiredBytes + SAFETY_FREE_SPACE_BYTES)
        } catch (_: Exception) {
            true
        }
    }

    fun postIncomingPromptNotification(context: Context, item: FileTransferItem) {
        try {
            appContext = context.applicationContext
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val chan = NotificationChannel(
                    CHANNEL_ID_FILES,
                    "File Transfers",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    enableVibration(true)
                }
                nm.createNotificationChannel(chan)
            }

            val acceptIntent = Intent(context, FileTransferActionReceiver::class.java).apply {
                action = FileTransferActionReceiver.ACTION_ACCEPT_TRANSFER
                putExtra(FileTransferActionReceiver.EXTRA_TRANSFER_ID, item.id)
            }
            val acceptPi = PendingIntent.getBroadcast(
                context,
                ("accept_" + item.id).hashCode(),
                acceptIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val declineIntent = Intent(context, FileTransferActionReceiver::class.java).apply {
                action = FileTransferActionReceiver.ACTION_DECLINE_TRANSFER
                putExtra(FileTransferActionReceiver.EXTRA_TRANSFER_ID, item.id)
            }
            val declinePi = PendingIntent.getBroadcast(
                context,
                ("decline_" + item.id).hashCode(),
                declineIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("open_tab", "files")
            }
            val contentPi = PendingIntent.getActivity(
                context,
                item.id.hashCode(),
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val title = if (item.isFolder) "Incoming Folder Archive from ${item.deviceName}" else "Incoming File from ${item.deviceName}"
            val body = if (item.isFolder) {
                "📁 \"${item.fileName}\" (${item.formattedTotalSize})\nFolder archive (.zip) · Confirm to accept."
            } else if (item.isExecutable) {
                "⚠️ \"${item.fileName}\" (${item.formattedTotalSize})\nExecutable file · Confirm to accept."
            } else {
                "\"${item.fileName}\" (${item.formattedTotalSize})"
            }

            val notif = NotificationCompat.Builder(context, CHANNEL_ID_FILES)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(contentPi)
                .addAction(0, "Accept", acceptPi)
                .addAction(0, "Decline", declinePi)
                .build()

            nm.notify(item.id.hashCode(), notif)
        } catch (_: Exception) {}
    }

    fun dismissPromptNotification(context: Context?, transferId: String) {
        try {
            val ctx = context ?: appContext ?: return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(transferId.hashCode())
        } catch (_: Exception) {}
    }

    private fun ensureProgressNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            if (nm.getNotificationChannel(CHANNEL_ID_TRANSFERS_PROGRESS) == null) {
                val chan = NotificationChannel(
                    CHANNEL_ID_TRANSFERS_PROGRESS,
                    "File Transfer Progress",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Shows live upload and download progress for active file and folder transfers"
                    enableLights(false)
                    enableVibration(false)
                    setShowBadge(false)
                }
                nm.createNotificationChannel(chan)
            }
        }
    }

    fun updateProgressNotification(context: Context, item: FileTransferItem) {
        try {
            ensureProgressNotificationChannel(context)
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

            val isOutgoing = item.direction == TransferDirection.OUTGOING
            val title = if (isOutgoing) {
                if (item.isFolder) "Sending folder \"${item.fileName}\"" else "Sending \"${item.fileName}\""
            } else {
                if (item.isFolder) "Receiving folder \"${item.fileName}\"" else "Receiving \"${item.fileName}\""
            }

            val speedText = item.formattedSpeed
            val etaText = item.remainingTimeText
            val pct = item.percentageInt
            val subtitle = if (speedText.isNotBlank()) {
                if (etaText.isNotBlank()) "$pct% · $speedText · $etaText" else "$pct% · $speedText"
            } else {
                "$pct% · ${item.formattedProgressSize}"
            }

            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("open_tab", "files")
            }
            val contentPi = PendingIntent.getActivity(
                context,
                ("open_" + item.id).hashCode(),
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val cancelIntent = Intent(context, FileTransferActionReceiver::class.java).apply {
                action = FileTransferActionReceiver.ACTION_CANCEL_TRANSFER
                putExtra(FileTransferActionReceiver.EXTRA_TRANSFER_ID, item.id)
            }
            val cancelPi = PendingIntent.getBroadcast(
                context,
                ("cancel_" + item.id).hashCode(),
                cancelIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val smallIcon = if (isOutgoing) android.R.drawable.stat_sys_upload else android.R.drawable.stat_sys_download

            val notif = NotificationCompat.Builder(context, CHANNEL_ID_TRANSFERS_PROGRESS)
                .setSmallIcon(smallIcon)
                .setContentTitle(title)
                .setContentText(subtitle)
                .setSubText(item.formattedTotalSize)
                .setProgress(100, pct, false)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(contentPi)
                .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Cancel", cancelPi)
                .build()

            nm.notify(("progress_" + item.id).hashCode(), notif)
        } catch (e: Exception) {
            Log.w(TAG, "Error updating progress notification: ${e.message}")
        }
    }

    fun dismissProgressNotification(context: Context?, transferId: String) {
        try {
            val ctx = context ?: appContext ?: return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            nm.cancel(("progress_" + transferId).hashCode())
        } catch (_: Exception) {}
    }

    private fun postFileSavedNotification(
        context: Context,
        fileName: String,
        macName: String,
        locationName: String,
        isFolder: Boolean = false
    ) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val chan = NotificationChannel(
                    CHANNEL_ID_FILES,
                    "File Transfers",
                    NotificationManager.IMPORTANCE_DEFAULT
                )
                nm.createNotificationChannel(chan)
            }

            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("open_tab", "files")
            }
            val pi = PendingIntent.getActivity(
                context,
                fileName.hashCode(),
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val title = if (isFolder) "Folder archive received from $macName" else "File received from $macName"
            val body = if (isFolder) {
                "📁 $fileName saved to $locationName · Tap to extract."
            } else if (isExecutable(fileName)) {
                "⚠️ $fileName saved to $locationName · Caution: Executable file."
            } else {
                "$fileName saved to $locationName"
            }

            val notif = NotificationCompat.Builder(context, CHANNEL_ID_FILES)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .setContentIntent(pi)
                .build()

            nm.notify(fileName.hashCode(), notif)
        } catch (_: Exception) {}
    }

    fun formatBytes(bytes: Long): String {
        val kb = bytes / 1024.0
        if (kb < 1.0) return "$bytes B"
        val mb = kb / 1024.0
        if (mb < 1.0) return String.format("%.1f KB", kb)
        val gb = mb / 1024.0
        if (gb < 1.0) return String.format("%.1f MB", mb)
        return String.format("%.2f GB", gb)
    }
}
