package com.jtycedgetech.amscan

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.assertFalse

/**
 * The report format is the CLI's, not this plugin's. These mirror
 * `editors/vscode/src/report.test.ts` so the two editors cannot drift.
 */
class ReportTest {
  private val sample = """
# Unused API model fields

**7 fields** · **3 classes** · scanned 2026-09-22 12:03 · 11 fields checked

- [ ] **SELECT EVERYTHING**

---

## Order

└ [lib/api/order.dart](../../lib/api/order.dart)

- [ ] **All of `Order`**

- [x] **`currency`** · 4 parts
  - [x] `field declaration` [line 4](../../lib/api/order.dart#L4) · [VS Code](vscode://file/tmp/p/lib/api/order.dart:4:1)
  - [ ] `map entry` [line 24](../../lib/api/order.dart#L24) · [VS Code](vscode://file/tmp/p/lib/api/order.dart:24:1)
""".trimIndent()

  @Test
  fun `reads the class, its field and its parts`() {
    val report = parseReport(sample)

    assertEquals(1, report.classes.size)
    val order = report.classes.single()
    assertEquals("Order", order.name)
    assertEquals(1, order.fields.size)
    assertEquals("currency", order.fields.single().name)
    assertEquals(2, order.fields.single().parts.size)
  }

  @Test
  fun `reads which boxes are ticked`() {
    val report = parseReport(sample)
    val field = report.classes.single().fields.single()

    assertTrue(field.checked)
    assertTrue(field.parts[0].checked)
    assertFalse(field.parts[1].checked)
    assertFalse(report.classes.single().checked)
  }

  @Test
  fun `takes the source location from the VS Code link`() {
    val part = parseReport(sample).classes.single().fields.single().parts[0]

    assertEquals("/tmp/p/lib/api/order.dart", part.file)
    assertEquals(4, part.sourceLine)
  }

  @Test
  fun `notes the class file and the select-all box`() {
    val report = parseReport(sample)

    assertEquals("lib/api/order.dart", report.classes.single().file)
    assertEquals(false, report.selectAll?.checked)
  }

  @Test
  fun `a report with nothing in it parses to nothing`() {
    val report = parseReport("# Title\n\nnothing here\n")

    assertTrue(report.classes.isEmpty())
    assertNull(report.selectAll)
  }
}
