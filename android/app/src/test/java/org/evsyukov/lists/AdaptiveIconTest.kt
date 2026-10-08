package org.evsyukov.lists

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.math.abs
import kotlin.math.hypot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/** The launcher icon against the masks a launcher may put on it. */
class AdaptiveIconTest {
    private val res = File("src/main/res")

    // An adaptive icon is 108 dp wide; a launcher shows the middle 72 dp under
    // its mask, and only a circle of radius 33 dp is promised to stay.
    private val centre = 54.0
    private val safeRadius = 33.0

    private fun root(path: String): Element =
        DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(File(res, path)).documentElement

    private fun elements(parent: Element, tag: String): List<Element> {
        val nodes = parent.getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    /** How far from the centre a path reaches, in units of the viewport before the group scale. */
    private fun reach(path: Element): Double {
        val stroke = if (path.hasAttribute("android:strokeColor")) path.getAttribute("android:strokeWidth").toDouble() / 2 else 0.0
        val tokens = Regex("[A-Za-z]|-?\\d*\\.?\\d+").findAll(path.getAttribute("android:pathData")).map { it.value }.toList()
        var i = 0
        var x = 0.0
        var y = 0.0
        var command = ' '
        var far = 0.0
        fun number() = tokens[i++].toDouble()
        fun visit(px: Double, py: Double, extra: Double = 0.0) {
            far = maxOf(far, hypot(px - centre, py - centre) + extra + stroke)
        }
        while (i < tokens.size) {
            if (tokens[i][0].isLetter()) command = tokens[i++][0]
            when (command) {
                'M', 'L' -> { x = number(); y = number(); visit(x, y); if (command == 'M') command = 'L' }
                'l' -> { x += number(); y += number(); visit(x, y) }
                'h' -> { x += number(); visit(x, y) }
                'a' -> {
                    val r = number()
                    i += 4
                    val dx = number()
                    val dy = number()
                    // The drawings use half circles only, so the centre of the arc is the middle of its chord.
                    assertEquals("an arc that is not a half circle", 2 * r, hypot(dx, dy), 1e-6)
                    visit(x + dx / 2, y + dy / 2, r)
                    x += dx
                    y += dy
                }
                'z', 'Z' -> Unit
                else -> throw AssertionError("path command $command is not handled")
            }
        }
        return far
    }

    private fun reachOfDrawing(path: String): Double {
        val vector = root(path)
        assertEquals("108", vector.getAttribute("android:viewportWidth"))
        assertEquals("108", vector.getAttribute("android:viewportHeight"))
        val group = elements(vector, "group").single()
        assertEquals(centre, group.getAttribute("android:pivotX").toDouble(), 0.0)
        assertEquals(centre, group.getAttribute("android:pivotY").toDouble(), 0.0)
        val scale = group.getAttribute("android:scaleX").toDouble()
        assertEquals(scale, group.getAttribute("android:scaleY").toDouble(), 0.0)
        val paths = elements(group, "path")
        assertEquals("paths outside the scaled group", paths.size, elements(vector, "path").size)
        return paths.maxOf { reach(it) } * scale
    }

    @Test
    fun foreground_stays_inside_the_safe_zone() {
        val reach = reachOfDrawing("drawable/ic_launcher_foreground.xml")
        assertTrue("the drawing reaches $reach dp from the centre", reach <= safeRadius)
    }

    @Test
    fun monochrome_stays_inside_the_safe_zone() {
        val reach = reachOfDrawing("drawable/ic_launcher_monochrome.xml")
        assertTrue("the drawing reaches $reach dp from the centre", reach <= safeRadius)
    }

    @Test
    fun monochrome_layer_has_its_own_drawing_with_the_check_mark_cut_out() {
        // A themed icon keeps only the alpha of the layer, so a check mark
        // drawn in another colour on the disc would vanish into it.
        val icon = root("mipmap-anydpi-v26/ic_launcher.xml")
        val foreground = elements(icon, "foreground").single().getAttribute("android:drawable")
        val monochrome = elements(icon, "monochrome").single().getAttribute("android:drawable")
        assertNotEquals(foreground, monochrome)
        assertEquals("@drawable/ic_launcher_monochrome", monochrome)

        val paths = elements(root("drawable/ic_launcher_monochrome.xml"), "path")
        val disc = paths.single { it.getAttribute("android:fillType") == "evenOdd" }
        val subpaths = disc.getAttribute("android:pathData").count { it == 'M' }
        assertEquals("the disc and the check mark inside it", 2, subpaths)
        val colours = paths.flatMap { listOf(it.getAttribute("android:fillColor"), it.getAttribute("android:strokeColor")) }
            .filter { it.isNotEmpty() }.toSet()
        assertEquals(setOf("#FFFFFFFF"), colours)
        assertTrue(abs(reachOfDrawing("drawable/ic_launcher_monochrome.xml") - reachOfDrawing("drawable/ic_launcher_foreground.xml")) < 1e-6)
    }
}
