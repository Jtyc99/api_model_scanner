package com.jtycedgetech.amscan

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.assertFalse

/** The messages the table sends back, in the shape `webview.ts` sends them. */
class MessageTest {
  @Test
  fun `a tick carries its line and the state it moved to`() {
    val message = parseMessage("""{"type":"set","line":12,"checked":true}""")!!

    assertEquals("set", message.type)
    assertEquals(12, message.line)
    assertTrue(message.checked)
  }

  @Test
  fun `an untick is distinguishable from a tick`() {
    assertFalse(parseMessage("""{"type":"set","line":3,"checked":false}""")!!.checked)
  }

  @Test
  fun `an open carries the file and the line to land on`() {
    val message =
      parseMessage("""{"type":"open","file":"/tmp/p/lib/a.dart","line":4}""")!!

    assertEquals("open", message.type)
    assertEquals("/tmp/p/lib/a.dart", message.file)
    assertEquals(4, message.line)
  }

  @Test
  fun `a path with escapes comes back as it went out`() {
    val message = parseMessage("""{"type":"open","file":"/a b\\c\"d"}""")!!

    assertEquals("""/a b\c"d""", message.file)
    assertNull(message.line)
  }

  @Test
  fun `a message with no type is ignored rather than guessed at`() {
    assertNull(parseMessage("""{"line":1}"""))
    assertNull(parseMessage("not json at all"))
    assertNull(parseMessage(""))
  }

  @Test
  fun `openAsText needs nothing else`() {
    assertEquals("openAsText", parseMessage("""{"type":"openAsText"}""")!!.type)
  }
}
