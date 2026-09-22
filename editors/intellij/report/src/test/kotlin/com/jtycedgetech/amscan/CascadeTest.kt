package com.jtycedgetech.amscan

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.assertFalse

/**
 * The cascade rules are the VS Code editor's, mirrored so the two cannot
 * disagree about what ticking a row means.
 */
class CascadeTest {
  private val text = """
- [ ] **SELECT EVERYTHING**

## Order

└ [lib/api/order.dart](../../lib/api/order.dart)

- [ ] **All of `Order`**

- [ ] **`currency`** · 2 parts
  - [ ] `field declaration` [line 4](../../lib/api/order.dart#L4)
  - [ ] `map entry` [line 24](../../lib/api/order.dart#L24)

- [ ] **`giftWrapped`** · 1 part
  - [ ] `field declaration` [line 5](../../lib/api/order.dart#L5)
""".trimIndent()

  private val report = parseReport(text)

  private fun lineOf(needle: String) =
    text.split('\n').indexOfFirst { it.contains(needle) }

  @Test
  fun `reading a box off a line`() {
    assertFalse(readBox(text, lineOf("SELECT EVERYTHING"))!!)
    assertNull(readBox(text, lineOf("## Order")))
  }

  @Test
  fun `setting a box that is already there writes nothing`() {
    assertNull(setBox(text, lineOf("SELECT EVERYTHING"), false))
  }

  @Test
  fun `an edit replaces only the character between the brackets`() {
    val line = lineOf("SELECT EVERYTHING")
    val edit = setBox(text, line, true)!!

    assertEquals(line, edit.line)
    assertEquals(text.split('\n')[line].indexOf('[') + 1, edit.column)
    assertEquals('x', edit.replacement)
  }

  @Test
  fun `ticking a field takes its parts with it`() {
    val state = desiredStates(report, lineOf("**`currency`**"), true)

    assertTrue(state[lineOf("**`currency`**")]!!)
    assertTrue(state[lineOf("`field declaration` [line 4]")]!!)
    assertTrue(state[lineOf("`map entry`")]!!)
  }

  @Test
  fun `a class is ticked only once every field under it is`() {
    val afterOne = desiredStates(report, lineOf("**`currency`**"), true)
    assertFalse(afterOne[lineOf("**All of `Order`**")]!!)

    // Ticking the class itself settles everything beneath it.
    val whole = desiredStates(report, lineOf("**All of `Order`**"), true)
    assertTrue(whole[lineOf("**`giftWrapped`**")]!!)
    assertTrue(whole[lineOf("**All of `Order`**")]!!)
    assertTrue(whole[lineOf("SELECT EVERYTHING")]!!)
  }

  @Test
  fun `unticking one part unticks its field and class`() {
    val ticked = desiredStates(report, lineOf("SELECT EVERYTHING"), true)
    assertTrue(ticked.values.all { it })

    // Apply, then untick a single part of the result.
    val applied = applyStates(text, ticked)
    val second = parseReport(applied)
    val state = desiredStates(second, lineOf("`map entry`"), false)

    assertFalse(state[lineOf("**`currency`**")]!!)
    assertFalse(state[lineOf("**All of `Order`**")]!!)
    assertFalse(state[lineOf("SELECT EVERYTHING")]!!)
    assertTrue(state[lineOf("**`giftWrapped`**")]!!)
  }
}
