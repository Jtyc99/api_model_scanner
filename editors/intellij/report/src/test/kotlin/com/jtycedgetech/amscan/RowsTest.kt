package com.jtycedgetech.amscan

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The flattening the table renders: one row per box, indented by depth. */
class RowsTest {
  private val report = parseReport(
    """
- [ ] **SELECT EVERYTHING**

## Order

└ [lib/api/order.dart](../../lib/api/order.dart)

- [ ] **All of `Order`**

- [x] **`currency`** · 1 part
  - [x] `field declaration` [line 4](../../lib/api/order.dart#L4) · [VS Code](vscode://file/tmp/p/lib/api/order.dart:4:1)
""".trimIndent(),
  )

  @Test
  fun `every box becomes a row, in document order`() {
    val rows = flatten(report)

    assertEquals(
      listOf("SELECT EVERYTHING", "Order", "currency", "field declaration"),
      rows.map { it.label.trim() },
    )
  }

  @Test
  fun `depth indents the label so the tree is readable`() {
    val rows = flatten(report)

    assertEquals(0, rows[0].depth)
    assertEquals(0, rows[1].depth)
    assertEquals(1, rows[2].depth)
    assertEquals(2, rows[3].depth)
    assertTrue(rows[3].label.startsWith("    "))
  }

  @Test
  fun `a part row carries where its source is`() {
    val part = flatten(report).last()

    assertEquals("/tmp/p/lib/api/order.dart", part.file)
    assertEquals(4, part.sourceLine)
  }

  @Test
  fun `rows report their own tick state and document line`() {
    val rows = flatten(report)

    assertEquals(false, rows[0].checked)
    assertEquals(true, rows[2].checked)
    assertTrue(rows.all { it.boxLine >= 0 })
  }

  @Test
  fun `a class header with no toggle of its own is still shown`() {
    // A class whose "All of" line is missing has column -1; it must still
    // appear, or its fields would float under no heading.
    val headless = parseReport("## Lonely\n\n- [ ] **`x`**\n")
    val rows = flatten(headless)

    assertEquals("Lonely", rows.first().label.trim())
    assertEquals(-1, rows.first().boxLine)
  }
}
