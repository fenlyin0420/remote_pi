package work.jacobmoura.remotepi

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileInputStream

/**
 * Writes a file the Pi handed us into the device's shared storage.
 *
 * The user asked "save this to my phone", so the file has to end up where they
 * can find it: an image in the gallery, anything else in Downloads. The app's
 * cache is useless for that — it is wiped by the system at any time and
 * invisible to every other app.
 *
 * MediaStore, not a raw write: since API 29 (this app's `minSdk` is 34) direct
 * writes to shared storage are impossible, and the MediaStore insert needs **no
 * storage permission at all** for files the app itself created. The
 * alternative — an `ACTION_CREATE_DOCUMENT` picker — would put a system dialog
 * in front of every save, which is the wrong trade for one tap.
 */
object MediaSaver {
    /** Album / folder both kinds land in, so repeat saves stay together. */
    private const val ALBUM = "Remote Pi"

    /**
     * Copy [source] into shared storage and return where it went.
     *
     * @param mime decides the collection: an image goes to the gallery (so the
     *   system Photos app indexes it), everything else to Downloads. Unknown
     *   mimes land in Downloads, which every file manager shows.
     * @return a human-readable location, e.g. `Pictures/Remote Pi/shot.png`.
     * @throws IllegalArgumentException when [source] is missing or unreadable.
     */
    fun save(context: Context, source: File, mime: String, displayName: String): String {
        if (!source.isFile) throw IllegalArgumentException("no such file: ${source.path}")
        val isImage = mime.startsWith("image/")
        val collection = if (isImage) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val relative = if (isImage) {
            "${Environment.DIRECTORY_PICTURES}/$ALBUM"
        } else {
            "${Environment.DIRECTORY_DOWNLOADS}/$ALBUM"
        }
        val name = sanitize(displayName)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime.ifEmpty { "application/octet-stream" })
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
                // Don't let the system index a half-written file.
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val resolver = context.contentResolver
        val target: Uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore refused the insert")
        try {
            resolver.openOutputStream(target)?.use { out ->
                FileInputStream(source).use { input -> input.copyTo(out) }
            } ?: throw IllegalStateException("cannot open the new entry for writing")
        } catch (error: Throwable) {
            // Never leave a zero-byte row behind claiming to be a photo.
            runCatching { resolver.delete(target, null, null) }
            throw error
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            resolver.update(
                target,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
        }
        return "$relative/$name"
    }

    /**
     * Publish a downloaded update APK into the root of the device's public
     * Downloads folder, under [displayName].
     *
     * Unlike [save] there is no album subfolder: the user asked for the APK
     * to sit where a file manager shows it, so it goes straight into
     * `Download/` with a version-stamped name. Same MediaStore plumbing —
     * scoped storage leaves no other option, and it needs no permission.
     *
     * A previous copy with the same name is deleted first, so a retry after a
     * release never leaves two APKs claiming to be the same version.
     */
    fun saveApk(context: Context, source: File, displayName: String): String {
        if (!source.isFile) throw IllegalArgumentException("no such file: ${source.path}")
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val name = sanitize(displayName)

        val resolver = context.contentResolver
        val collectionUri = collection
        val existing = resolver.query(
            collectionUri,
            arrayOf(MediaStore.Downloads._ID),
            "${MediaStore.Downloads.DISPLAY_NAME} = ?",
            arrayOf(name),
            null,
        )
        if (existing != null) {
            val idColumn = existing.getColumnIndex(MediaStore.Downloads._ID)
            val ids = mutableListOf<Long>()
            while (idColumn >= 0 && existing.moveToNext()) {
                ids.add(existing.getLong(idColumn))
            }
            existing.close()
            ids.forEach { id ->
                resolver.delete(collectionUri, "_id = ?", arrayOf(id.toString()))
            }
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/vnd.android.package-archive")
            put(MediaStore.MediaColumns.SIZE, source.length())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                // Don't let the system offer a half-written APK for install.
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val target: Uri = resolver.insert(collectionUri, values)
            ?: throw IllegalStateException("MediaStore refused the insert")
        try {
            resolver.openOutputStream(target)?.use { out ->
                FileInputStream(source).use { input -> input.copyTo(out) }
            } ?: throw IllegalStateException("cannot open the new entry for writing")
        } catch (error: Throwable) {
            runCatching { resolver.delete(target, null, null) }
            throw error
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            resolver.update(
                target,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
        }
        return "${Environment.DIRECTORY_DOWNLOADS}/$name"
    }

    /**
     * Strip anything that would make a bad file name: separators, the NUL-ish
     * control characters, and the two-character sequences Android treats as
     * path traversal. The name comes off the wire (a Pi-supplied file name),
     * so it is untrusted input.
     */
    private fun sanitize(raw: String): String {
        val cleaned = raw
            .replace(Regex("[\\u0000-\\u001f\\u007f]"), "")
            .replace("/", "_")
            .replace("..", "_")
            .trim()
            .trim('.')
        return cleaned.take(120).ifEmpty { "file" }
    }
}
