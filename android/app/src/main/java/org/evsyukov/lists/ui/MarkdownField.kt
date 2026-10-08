package org.evsyukov.lists.ui

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.em
import uniffi.lists_core.MarkdownAlign
import uniffi.lists_core.MarkdownKind
import uniffi.lists_core.MarkdownLayout
import uniffi.lists_core.markdownLayout
import uniffi.lists_core.markdownNewline

/** Colours of a note shown as Markdown; they come from the theme. */
data class MarkdownColors(val dim: Color, val link: Color, val code: Color, val heading: Color)

/**
 * What laying a table out as a grid needs (R60): the width in pixels a piece of
 * the note takes in the field, the width there is, zero while unknown, and the
 * way from pixels to the unit of letter spacing.
 */
class GridMetrics(val width: (AnnotatedString) -> Float, val available: Float, val spacing: (Float) -> TextUnit)

/**
 * A note as it is shown (R48–R51): the text with the markup taken out, bullets,
 * quote bars and checkboxes put in, and the way back from every shown character
 * to the typed one. The typed text itself is never changed here.
 */
class MarkdownView(text: String, layout: MarkdownLayout, selection: TextRange?, colors: MarkdownColors, grid: GridMetrics? = null) {
    /** Shown offsets of the checkboxes with the typed offset of the character between their brackets. */
    val boxes: List<Pair<Int, Int>>
    /** Shown ranges of the links with their addresses. */
    val links: List<Pair<IntRange, String>>
    val shown: AnnotatedString
    val mapping: OffsetMapping

    init {
        val n = text.length
        val drop = BooleanArray(n)
        val swap = arrayOfNulls<String>(n)
        val styles = ArrayList<Triple<SpanStyle, Int, Int>>()
        val boxAt = ArrayList<Int>()
        val linkAt = ArrayList<Pair<IntRange, String>>()
        // Markup shows in the blocks the selection touches; a note without the keyboard has none.
        val active = layout.blocks.map { block ->
            selection != null && block.start.toInt() <= selection.max && selection.min <= block.end.toInt()
        }
        val dim = SpanStyle(color = colors.dim)
        // R60: the tables to show as a grid, each with the lines of its rows and the line of
        // dashes. A table stays as typed while the cursor is in it, and where it does not
        // start its line: in a list item or a quote.
        val grids = if (grid == null) emptyList() else layout.tables.mapNotNull { table ->
            val start = table.start.toInt()
            val end = table.end.toInt()
            if (end > n || active.getOrElse(table.block.toInt()) { true } || (start > 0 && text[start - 1] != '\n')) return@mapNotNull null
            val lines = ArrayList<IntRange>()
            var at = start
            while (at <= end) {
                val stop = text.indexOf('\n', at).let { if (it < 0 || it > end) end else it }
                lines += at until stop
                at = stop + 1
            }
            if (lines.size != table.rows.size + 1) null else Triple(table, listOf(lines[0]) + lines.drop(2), lines[1])
        }
        fun inGrid(at: Int) = grids.any { (_, lines, rule) -> at in rule || lines.any { at in it } }
        for (span in layout.spans) {
            val start = span.start.toInt()
            val end = span.end.toInt()
            if (end > n || start >= end) continue
            val open = active.getOrElse(span.block.toInt()) { false }
            when (val kind = span.kind) {
                is MarkdownKind.Heading -> {
                    val scale = listOf(1.5f, 1.3f, 1.15f, 1f, 1f, 1f)[(kind.level.toInt() - 1).coerceIn(0, 5)]
                    styles += Triple(SpanStyle(fontWeight = FontWeight.Bold, fontSize = scale.em, color = colors.heading), start, end)
                }
                MarkdownKind.Strong -> styles += Triple(SpanStyle(fontWeight = FontWeight.Bold), start, end)
                MarkdownKind.Emphasis -> styles += Triple(SpanStyle(fontStyle = FontStyle.Italic), start, end)
                MarkdownKind.Strikethrough -> styles += Triple(SpanStyle(textDecoration = TextDecoration.LineThrough), start, end)
                MarkdownKind.Code, MarkdownKind.CodeBlock ->
                    styles += Triple(SpanStyle(fontFamily = FontFamily.Monospace, background = colors.code), start, end)
                MarkdownKind.TableRow -> if (!inGrid(start)) styles += Triple(SpanStyle(fontFamily = FontFamily.Monospace), start, end)
                MarkdownKind.Quote -> styles += Triple(SpanStyle(fontStyle = FontStyle.Italic), start, end)
                is MarkdownKind.Link -> {
                    styles += Triple(SpanStyle(color = colors.link, textDecoration = TextDecoration.Underline), start, end)
                    linkAt += (start until end) to kind.url
                }
                is MarkdownKind.ListMarker ->
                    if (open && !kind.ordered) styles += Triple(dim, start, end)
                    else if (!kind.ordered && end - start == 1) swap[start] = "•"
                MarkdownKind.QuoteMarker ->
                    if (open) styles += Triple(dim, start, end)
                    else {
                        swap[start] = "▎"
                        // Upright, whatever the quote around it is set in.
                        styles += Triple(dim.copy(fontStyle = FontStyle.Normal), start, start + 1)
                    }
                is MarkdownKind.Checkbox -> {
                    // The brackets come back only when the cursor is right at them.
                    val touched = selection != null && selection.min <= end && start <= selection.max
                    if (touched || end - start != 3) styles += Triple(dim, start, end)
                    else {
                        swap[start] = if (kind.checked) "☑" else "☐"
                        drop[start + 1] = true
                        drop[start + 2] = true
                        boxAt += start
                    }
                }
                MarkdownKind.Rule ->
                    if (open) styles += Triple(dim, start, end)
                    else {
                        for (i in start until end) swap[i] = "─"
                        styles += Triple(dim, start, end)
                    }
                MarkdownKind.Markup ->
                    if (open) styles += Triple(dim, start, end)
                    else {
                        for (i in start until end) drop[i] = true
                        // Markup that is a whole line, a code fence, leaves no empty line behind.
                        val wholeLine = (start == 0 || text[start - 1] == '\n') && (end == n || text[end] == '\n')
                        if (wholeLine && end < n) drop[end] = true else if (wholeLine && start > 0) drop[start - 1] = true
                    }
            }
        }

        /** A piece of the note as it is shown, for measuring a cell. */
        fun piece(from: Int, to: Int) = AnnotatedString.Builder().apply {
            val at = IntArray(to - from + 1)
            for (i in from until to) {
                at[i - from] = length
                if (!drop[i]) append(swap[i] ?: text[i].toString())
            }
            at[to - from] = length
            for ((style, start, end) in styles) {
                val a = at[start.coerceIn(from, to) - from]
                val b = at[end.coerceIn(from, to) - from]
                if (a < b) addStyle(style, a, b)
            }
        }.toAnnotatedString()

        for ((table, lines, rule) in grids) {
            val metrics = grid ?: break
            val mono = { for (line in lines + listOf(rule)) styles += Triple(SpanStyle(fontFamily = FontFamily.Monospace), line.first, line.last + 1) }
            val columns = table.columns.size
            val cells = table.rows.map { row -> row.cells.map { it.start.toInt() to it.end.toInt() } }
            // What the parser made of a row has to lie in its line, in order; otherwise the table stays as typed.
            val sound = columns > 0 && cells.zip(lines).all { (row, line) ->
                row.size == columns && row.first().first >= line.first && row.last().second <= line.last + 1 &&
                    row.zipWithNext().all { (a, b) -> a.second <= b.first }
            }
            if (!sound) { mono(); continue }
            val bold = SpanStyle(fontWeight = FontWeight.Bold, color = colors.heading)
            for ((row, cellsOf) in table.rows.zip(cells)) if (row.header) for ((from, to) in cellsOf) if (from < to) styles += Triple(bold, from, to)
            val widths = cells.map { row -> row.map { (from, to) -> if (from < to) metrics.width(piece(from, to)) else 0f } }
            val column = (0 until columns).map { index -> widths.maxOf { it[index] } }
            val space = metrics.width(AnnotatedString(" "))
            val gap = space * 4
            // A grid is not wrapped: a table wider than the note stays as typed.
            if (metrics.available > 0 && column.sum() + gap * (columns - 1) > metrics.available) { mono(); continue }
            /** Room on the left of a cell in its column: all of the spare for a right column, half for a centred one. */
            fun before(row: Int, index: Int): Float {
                val spare = column[index] - widths[row][index]
                return when (table.columns[index]) {
                    MarkdownAlign.RIGHT -> spare
                    MarkdownAlign.CENTER -> spare / 2
                    else -> 0f
                }
            }
            /** Turns one character of `range` into a space of this width and drops the rest. */
            fun spacer(range: IntRange, keep: Int?, width: Float) {
                for (i in range) drop[i] = true
                if (keep == null || width < 0.5f) return
                drop[keep] = false
                swap[keep] = " "
                styles += Triple(SpanStyle(letterSpacing = metrics.spacing(width - space)), keep, keep + 1)
            }
            for ((number, pair) in cells.zip(lines).withIndex()) {
                val (row, line) = pair
                val lead = line.first until row[0].first
                spacer(lead, lead.firstOrNull(), before(number, 0))
                for (index in 0 until columns - 1) {
                    val between = row[index].second until row[index + 1].first
                    val after = column[index] - widths[number][index] - before(number, index)
                    spacer(between, between.firstOrNull { text[it] == '|' }, after + gap + before(number, index + 1))
                }
                spacer(row.last().second..line.last, null, 0f)
            }
            // The line of dashes takes no room.
            for (i in rule) drop[i] = true
            if (rule.last + 1 < n) drop[rule.last + 1] = true
        }

        val out = StringBuilder(n)
        val toShown = IntArray(n + 1)
        val toTyped = ArrayList<Int>(n + 1)
        for (i in 0 until n) {
            toShown[i] = out.length
            if (drop[i]) continue
            out.append(swap[i] ?: text[i])
            toTyped += i
        }
        toShown[n] = out.length
        toTyped += n

        shown = AnnotatedString.Builder(out.toString()).apply {
            for ((style, start, end) in styles) {
                val from = toShown[start]
                val to = toShown[end]
                if (from < to) addStyle(style, from, to)
            }
        }.toAnnotatedString()
        boxes = boxAt.map { toShown[it] to it + 1 }
        links = linkAt.mapNotNull { (range, url) ->
            val from = toShown[range.first]
            val to = toShown[range.last + 1]
            if (from < to) (from until to) to url else null
        }
        mapping = object : OffsetMapping {
            override fun originalToTransformed(offset: Int) = toShown[offset.coerceIn(0, n)]
            override fun transformedToOriginal(offset: Int) = toTyped[offset.coerceIn(0, toTyped.size - 1)]
        }
    }
}

/** The note after Return was typed at `cursor - 1`, when the list or the quote there goes on (R52). */
private fun continued(before: TextFieldValue, after: TextFieldValue): TextFieldValue? {
    val cursor = after.selection.start
    val typedReturn = after.selection.collapsed && before.selection.collapsed &&
        after.text.length == before.text.length + 1 && cursor == before.selection.start + 1 &&
        after.text.getOrNull(cursor - 1) == '\n' && after.text.removeRange(cursor - 1, cursor) == before.text
    if (!typedReturn) return null
    val edit = markdownNewline(before.text, before.selection.start.toUInt()) ?: return null
    val text = before.text.replaceRange(edit.start.toInt(), edit.end.toInt(), edit.text)
    return TextFieldValue(text, TextRange(edit.cursor.toInt().coerceIn(0, text.length)))
}

/**
 * The note of a task: typed as text, shown as Markdown while it is typed.
 * Saved when the field loses the keyboard and when a checkbox is tapped.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MarkdownField(
    key: String,
    value: String,
    placeholder: String,
    enabled: Boolean,
    textStyle: TextStyle,
    modifier: Modifier,
    onCommit: (String) -> Unit,
) {
    var field by remember(key) { mutableStateOf(TextFieldValue(value)) }
    var focused by remember(key) { mutableStateOf(false) }
    var textLayout by remember(key) { mutableStateOf<TextLayoutResult?>(null) }
    val saved by rememberUpdatedState(value)
    val commit by rememberUpdatedState(onCommit)
    val uriHandler = LocalUriHandler.current
    val interaction = remember { MutableInteractionSource() }
    // An edit arriving from another device replaces the text unless the user is typing here.
    LaunchedEffect(value) { if (!focused && field.text != value) field = TextFieldValue(value) }
    fun save() {
        val trimmed = field.text.trim()
        if (trimmed != saved) commit(trimmed)
    }
    DisposableEffect(key) { onDispose { if (focused) save() } }

    val scheme = MaterialTheme.colorScheme
    val colors = MarkdownColors(dim = scheme.outline, link = scheme.primary, code = scheme.surfaceVariant, heading = scheme.onSurface)
    val layout = remember(field.text) { markdownLayout(field.text) }
    // Keyed by the text as well: two texts can have the same ranges, a word replaced by one of its length.
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val shownStyle = textStyle.copy(color = LocalContentColor.current)
    // The width the field may take; known after the first layout.
    val available = textLayout?.layoutInput?.constraints?.maxWidth?.takeIf { it != Constraints.Infinity } ?: 0
    val view = remember(field.text, layout, field.selection, focused, colors, available, shownStyle) {
        val metrics = GridMetrics(
            width = { piece -> measurer.measure(piece, shownStyle, softWrap = false, maxLines = 1).size.width.toFloat() },
            available = available.toFloat(),
            spacing = { with(density) { it.toSp() } },
        )
        MarkdownView(field.text, layout, field.selection.takeIf { focused }, colors, metrics)
    }
    val current by rememberUpdatedState(view)
    val transformation = remember(view) { VisualTransformation { TransformedText(view.shown, view.mapping) } }

    BasicTextField(
        value = field,
        onValueChange = { next -> field = continued(field, next) ?: next },
        enabled = enabled,
        textStyle = shownStyle,
        keyboardOptions = SentenceKeyboard,
        cursorBrush = SolidColor(scheme.primary),
        visualTransformation = transformation,
        interactionSource = interaction,
        onTextLayout = { textLayout = it },
        modifier = modifier
            .onFocusChanged {
                if (focused && !it.isFocused) save()
                focused = it.isFocused
            },
        decorationBox = { inner ->
            TextFieldDefaults.DecorationBox(
                value = field.text,
                innerTextField = {
                    Box(
                        Modifier.pointerInput(key, enabled) {
                            if (!enabled) return@pointerInput
                            awaitEachGesture {
                                val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                                val result = textLayout ?: return@awaitEachGesture
                                val at = down.position
                                val shown = current
                                fun hit(offset: Int) = offset < result.layoutInput.text.length && result.getBoundingBox(offset).contains(at)
                                val box = shown.boxes.firstOrNull { hit(it.first) }
                                val link = shown.links.firstOrNull { (range, _) -> range.any(::hit) }
                                if (box != null) {
                                    down.consume()
                                    val up = waitForUpOrCancellation(PointerEventPass.Initial) ?: return@awaitEachGesture
                                    up.consume()
                                    val mark = box.second
                                    val text = field.text
                                    if (mark < text.length) {
                                        val flipped = if (text[mark] == ' ') 'x' else ' '
                                        field = field.copy(text = text.replaceRange(mark, mark + 1, flipped.toString()))
                                        save()
                                    }
                                } else if (link != null) {
                                    // R71: a tap opens the link, with the keyboard in the note or not. The press stays
                                    // with the field, so a long press selects; the lift is taken, so the cursor stays.
                                    val up = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                                        waitForUpOrCancellation(PointerEventPass.Initial)
                                    } ?: return@awaitEachGesture
                                    up.consume()
                                    runCatching { uriHandler.openUri(link.second) }
                                }
                            }
                        },
                    ) { inner() }
                },
                enabled = enabled,
                singleLine = false,
                visualTransformation = transformation,
                interactionSource = interaction,
                placeholder = { Text(placeholder) },
                colors = transparentField(),
            )
        },
    )
}
