package com.jtycedgetech.amscan

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The webview is handed the same shape `report.ts` produces, so one piece of
 * rendering JavaScript serves both editors.
 */
class JsonTest {
  private val report = parseReport(
    """
- [ ] **SELECT EVERYTHING**

## Order

└ [lib/api/order.dart](../../lib/api/order.dart)

- [x] **All of `Order`**

- [x] **`currency`** · 1 part
  - [x] `field declaration` [line 4](../../lib/api/order.dart#L4) · [VS Code](vscode://file/tmp/p/lib/api/order.dart:4:1)
""".trimIndent(),
  )

  @Test
  fun `carries the field names the renderer draws`() {
    val json = report.toJson()

    assertTrue(json.contains(""""name":"Order""""))
    assertTrue(json.contains(""""name":"currency""""))
    assertTrue(json.contains(""""label":"field declaration""""))
  }

  @Test
  fun `carries the positions a toggle needs`() {
    val json = report.toJson()

    assertTrue(json.contains(""""line":"""), "box lines drive every edit")
    assertTrue(json.contains(""""column":"""), "column decides if a class is tickable")
    assertTrue(json.contains(""""sourceLine":4"""))
    assertTrue(json.contains(""""file":"/tmp/p/lib/api/order.dart""""))
  }

  @Test
  fun `a missing value is null rather than absent`() {
    val bare = parseReport("## Lonely\n\n- [ ] **`x`**\n").toJson()

    assertTrue(bare.contains(""""file":null"""))
    assertTrue(bare.contains(""""selectAll":null"""))
  }

  @Test
  fun `text that would break the document is escaped`() {
    val nasty = Row("a\"b\\c\nd", false, 1, 0)
    assertEquals("\"a\\\"b\\\\c\\nd\"", jsonString(nasty.label))
  }

  @Test
  fun `the dead flag survives, since the renderer marks those classes`() {
    val dead = parseReport(
      "## Gone\n\n- [ ] **All of `Gone`**\n\n> 💀 **`Gone` is dead.**\n",
    )
    assertTrue(dead.toJson().contains(""""dead":true"""))
  }
}
