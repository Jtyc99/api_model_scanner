package com.jtycedgetech.amscan

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The disabled report, byte for byte as the Dart CLI writes it. */
class DisabledTest {
  private val text = """
# Disabled API model fields

**2 fields** commented out but still present in the source · 1 read dynamically.

Tick what you want, then run `amscan disable --undo` to put it back or `amscan disable --remove` to delete it for good. With nothing ticked, both offer to act on everything — though `--remove` never takes a field read dynamically without a tick of its own.

This file disappears once nothing is disabled.

---

**⚠️ Read dynamically — deleted for good only when you tick them**

A field of the same name was read through a dynamic receiver when these were disabled, so the app may throw wherever that read runs until they are back. --undo puts them back along with everything else; --remove takes one only when it is ticked itself.

### DepositBank

Declared in [lib/models/person.dart](../../lib/models/person.dart)

* [ ] **`minAmount`** · 3 snippets · read at [lib/app.dart:6](vscode://file/Users/me/app/lib/app.dart:6:1)
  * `final double minAmount;`
  * `required this.minAmount,`
  * `minAmount: (json['minAmount'] as num).toDouble(),`

---

**Disabled — safe to select together**

- [ ] **SELECT EVERYTHING**

---

## DepositBank

└ [lib/models/person.dart](../../lib/models/person.dart)

- [ ] **All of `DepositBank`**

- [ ] **`branch`** · 3 snippets
  - `final String branch;`
  - `required this.branch,`
  - `branch: json['branch'] as String,`
""".trimStart('\n')

  private val report = parseReport(text)

  @Test
  fun `dynamic fields are apart, under the report's own headings`() {
    assertEquals(listOf("minAmount"), report.guarded.flatMap { c -> c.fields.map { it.name } })
    assertEquals(listOf("branch"), report.classes.flatMap { c -> c.fields.map { it.name } })
    assertEquals("Disabled — safe to select together", report.mainTitle)
    assertTrue(report.guardedTitle!!.contains("deleted for good only when you tick them"))
    assertTrue(report.guardedNote!!.contains("--undo puts them back"))
  }

  @Test
  fun `each field shows the code it had commented out`() {
    // Snippet rows carry no checkbox, and were once read as nothing at all —
    // every disabled field showed "No removable declaration found".
    val minAmount = report.guarded.single().fields.single()
    assertEquals(3, minAmount.snippets.size)
    assertEquals("final String branch;", report.classes.single().fields.single().snippets.first())
    assertEquals(listOf("lib/app.dart:6"), minAmount.reads.map { it.label })
  }

  @Test
  fun `a class keeps its file after the main heading`() {
    // A heading's note is the first prose after it, and nothing further: the
    // class's file line must never be taken for one.
    assertEquals("lib/models/person.dart", report.classes.single().file)
  }

  @Test
  fun `Select Everything never reaches the guarded section`() {
    val states = desiredStates(report, report.selectAll!!.line, true)

    assertEquals(false, states[report.guarded.single().fields.single().line])
    assertEquals(true, states[report.classes.single().fields.single().line])
  }

  @Test
  fun `the page is handed the headings and the snippets`() {
    val json = report.toJson()

    assertTrue(json.contains(""""mainTitle":"Disabled — safe to select together""""))
    assertTrue(json.contains(""""snippets":["final String branch;""""))
  }
}
