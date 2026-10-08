package org.evsyukov.lists.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color as AndroidColor
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.media.ExifInterface
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.SaveAlt
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.evsyukov.lists.R
import org.evsyukov.lists.str
import uniffi.lists_core.Attachment
import java.io.File
import kotlin.math.max

/** What the app shows by itself (R54); everything else goes to another app. */
enum class PreviewKind { IMAGE, PDF }

/** The types the platform decodes without help. SVG is an image by its type, but not one of them. */
fun previewKind(mime: String): PreviewKind? = when (mime) {
    "image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/heif", "image/bmp" -> PreviewKind.IMAGE
    "application/pdf" -> PreviewKind.PDF
    else -> null
}

/**
 * Reads an image no larger than needed: the longer side of the result is at
 * least [side] pixels when the file has that many, and less than twice that.
 * A photo is turned the way its EXIF says. Null when the file is not an image.
 */
fun decodeImage(path: String, side: Int): Bitmap? = runCatching {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    var sample = 1
    while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= side) sample *= 2
    val bitmap = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
    val degrees = when (ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
        ExifInterface.ORIENTATION_ROTATE_90 -> 90f
        ExifInterface.ORIENTATION_ROTATE_180 -> 180f
        ExifInterface.ORIENTATION_ROTATE_270 -> 270f
        else -> 0f
    }
    if (degrees == 0f) bitmap
    else Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(degrees) }, true)
}.getOrNull()

/** The icon of an attachment row: a thumbnail for an image (R55), a symbol for the rest. */
@Composable
fun AttachmentIcon(file: Attachment) {
    val path = file.localPath?.takeIf { previewKind(file.mime) == PreviewKind.IMAGE }
    val pixels = with(LocalDensity.current) { 40.dp.roundToPx() }
    val thumbnail by produceState<Bitmap?>(null, path) {
        value = path?.let { withContext(Dispatchers.IO) { decodeImage(it, pixels) } }
    }
    val bitmap = thumbnail
    // One width for both, so the names of the files stay in a column.
    Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) {
        if (bitmap != null) {
            Image(
                bitmap.asImageBitmap(), null,
                Modifier.fillMaxSize().clip(RoundedCornerShape(6.dp)).testTag("thumbnail"),
                contentScale = ContentScale.Crop,
            )
        } else {
            Icon(
                if (file.mime.startsWith("image/")) Icons.Outlined.Image else Icons.AutoMirrored.Outlined.InsertDriveFile,
                null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * An image or a PDF over the whole screen (R54). [onOpenOutside] hands the
 * file to another app, which is also the way out when it cannot be shown.
 */
@Composable
fun AttachmentViewer(file: Attachment, kind: PreviewKind, onOpenOutside: () -> Unit, onSave: () -> Unit, onShare: () -> Unit, onClose: () -> Unit) {
    val path = file.localPath ?: return
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(Modifier.fillMaxSize().background(Color.Black).systemBarsPadding().testTag("viewer")) {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(file.name, Modifier.weight(1f), color = Color.White, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                IconButton(onClick = onSave) { Icon(Icons.Outlined.SaveAlt, str(R.string.save_to), tint = Color.White) }
                IconButton(onClick = onShare) { Icon(Icons.Outlined.Share, str(R.string.share), tint = Color.White) }
                IconButton(onClick = onOpenOutside) { Icon(Icons.AutoMirrored.Outlined.OpenInNew, str(R.string.open_in_another_app), tint = Color.White) }
                IconButton(onClick = onClose) { Icon(Icons.Outlined.Close, str(R.string.close), tint = Color.White) }
            }
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                when (kind) {
                    PreviewKind.IMAGE -> ZoomableImage(path)
                    PreviewKind.PDF -> PdfPages(path)
                }
            }
        }
    }
}

@Composable
private fun CannotShow() {
    Text(str(R.string.cannot_show_file), Modifier.padding(24.dp), color = Color.White)
}

/** The image fitted to the screen; two fingers and a double tap zoom it, a drag moves it while zoomed. */
@Composable
private fun ZoomableImage(path: String) {
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val side = max(constraints.maxWidth, constraints.maxHeight)
        val loaded by produceState<Result<Bitmap?>?>(null, path, side) {
            value = Result.success(withContext(Dispatchers.IO) { decodeImage(path, side) })
        }
        val bitmap = loaded?.getOrNull()
        if (loaded != null && bitmap == null) return@BoxWithConstraints CannotShow()
        if (bitmap == null) return@BoxWithConstraints

        var scale by remember(path) { mutableFloatStateOf(1f) }
        var offset by remember(path) { mutableStateOf(Offset.Zero) }
        var size by remember { mutableStateOf(IntSize.Zero) }
        // The picture never leaves the screen: it can be moved only by what the zoom added.
        fun held(to: Offset, at: Float): Offset {
            val x = size.width * (at - 1f) / 2f
            val y = size.height * (at - 1f) / 2f
            return Offset(to.x.coerceIn(-x, x), to.y.coerceIn(-y, y))
        }
        Image(
            bitmap.asImageBitmap(), null,
            Modifier.fillMaxSize().onSizeChanged { size = it }
                .pointerInput(path) {
                    detectTapGestures(onDoubleTap = {
                        if (scale > 1f) { scale = 1f; offset = Offset.Zero } else scale = 2.5f
                    })
                }
                .pointerInput(path) {
                    detectTransformGestures { _, pan, zoom, _ ->
                        scale = (scale * zoom).coerceIn(1f, 8f)
                        offset = held(offset + pan, scale)
                    }
                }
                .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offset.x, translationY = offset.y)
                .testTag("viewer-image"),
            contentScale = ContentScale.Fit,
        )
    }
}

/**
 * A PDF opened with the renderer of the platform. It draws one page at a time
 * and may not be closed while it draws, so both go through one lock.
 */
private class PdfFile(path: String) {
    private val renderer = PdfRenderer(ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY))
    private var closed = false
    val pages: Int = renderer.pageCount

    @Synchronized
    fun page(index: Int, width: Int): Bitmap? {
        if (closed) return null
        return renderer.openPage(index).use { page ->
            val height = max(1, width * page.height / max(1, page.width))
            Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                it.eraseColor(AndroidColor.WHITE)
                page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            }
        }
    }

    @Synchronized
    fun close() {
        if (!closed) renderer.close()
        closed = true
    }
}

/** The pages one under another, each drawn when it comes on screen. */
@Composable
private fun PdfPages(path: String) {
    // A file that is not a PDF, or one that asks for a password, cannot be opened.
    val pdf = remember(path) { runCatching { PdfFile(path) }.getOrNull() }
    DisposableEffect(pdf) { onDispose { pdf?.close() } }
    if (pdf == null) return CannotShow()
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = constraints.maxWidth.coerceIn(1, 2048)
        LazyColumn(Modifier.fillMaxSize().testTag("viewer-pdf"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(pdf.pages) { index ->
                val page by produceState<Bitmap?>(null, pdf, index, width) {
                    value = withContext(Dispatchers.IO) { runCatching { pdf.page(index, width) }.getOrNull() }
                }
                val bitmap = page
                if (bitmap != null) {
                    Image(bitmap.asImageBitmap(), "${index + 1} / ${pdf.pages}", Modifier.fillMaxWidth(), contentScale = ContentScale.FillWidth)
                } else {
                    // Roughly a sheet of paper, so the list does not jump when the page arrives.
                    Box(Modifier.fillMaxWidth().aspectRatio(0.707f).background(Color.White))
                }
            }
        }
    }
}
