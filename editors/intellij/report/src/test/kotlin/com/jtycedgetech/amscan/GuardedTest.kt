package com.jtycedgetech.amscan

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * A report with fields read through `dynamic`, byte for byte as the Dart
 * renderer writes it. Those fields live in a section no editor released
 * before it can parse — so an older editor's Select Everything cannot tick
 * them. These checks hold for that older parser and must keep holding.
 */
class GuardedTest {
  private val text = """
# Unused API model fields

**1 field** · **1 class** · **1 read dynamically** · scanned 2026-09-29 16:07 · 4 fields checked

Tick what you want to act on, then run `amscan remove` to delete it or `amscan disable` to comment it out.

Ticking a class or field selects everything under it. Ticking `field declaration` takes the whole field, since nothing else can reference a field that no longer exists. With nothing ticked, both commands offer to act on everything under SELECT EVERYTHING — never on the fields read dynamically, listed first.

Every row links twice, because no single link works everywhere: **line N** is a relative path, which most editors will open, while **VS Code** is the form that lands the cursor on the exact line in the editor this scan was run from.

---

**⚠️ Read dynamically — taken only when you tick them**

Nothing references these by type, but a field of the same name is read through a `dynamic` receiver — `for (final bank in list ?? [])` makes `bank` dynamic — and no reference search can follow that. Removing one still compiles, then throws `NoSuchMethodError` when the read runs.

Matching is by name alone, since a dynamic receiver cannot say which class it holds, so some of these may be truly unused. Give each receiver a type and rescan — or tick a field here once you have checked it. SELECT EVERYTHING, a class tick and `--all` never reach this section.

### DepositBank

Declared in [lib/models/person.dart](../../lib/models/person.dart)

* [ ] **`minAmount`** · 3 parts · read at [lib/app.dart:6](vscode://file/Users/me/app/lib/app.dart:6:1)
  * [ ] `field declaration              ` [line 14](../../lib/models/person.dart#L14) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:14:1)
  * [ ] `constructor parameter minAmount` [line 19](../../lib/models/person.dart#L19) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:19:1)
  * [ ] `named argument minAmount       ` [line 25](../../lib/models/person.dart#L25) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:25:1)

---

**Unused — safe to select together**

- [ ] **SELECT EVERYTHING**

---

## DepositBank

└ [lib/models/person.dart](../../lib/models/person.dart)

- [ ] **All of `DepositBank`**

- [ ] **`branch`** · 3 parts
  - [ ] `field declaration           ` [line 16](../../lib/models/person.dart#L16) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:16:1)
  - [ ] `constructor parameter branch` [line 21](../../lib/models/person.dart#L21) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:21:1)
  - [ ] `named argument branch       ` [line 27](../../lib/models/person.dart#L27) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:27:1)
""".trimStart('\n')

  private val report = parseReport(text)

  private fun lineOf(needle: String) =
    text.split('\n').indexOfFirst { it.contains(needle) }

  @Test
  fun `the ordinary table holds only what the scan could vouch for`() {
    assertEquals(listOf("branch"), report.classes.flatMap { c -> c.fields.map { it.name } })
  }

  @Test
  fun `the banner does not replace the title`() {
    assertEquals("Unused API model fields", report.title)
  }

  /** The guarded section alone: from its banner to Select Everything. */
  private val section = lineOf("Read dynamically") until lineOf("**SELECT EVERYTHING**")

  @Test
  fun `Select Everything never reaches the guarded section`() {
    val states = desiredStates(report, lineOf("**SELECT EVERYTHING**"), true)

    // An older parser leaves those lines out of the map; this one carries
    // them through unchanged. Either way, none of them may end up ticked.
    val ticked = states.filter { (line, on) -> line in section && on }.keys
    assertTrue(!section.isEmpty())
    assertTrue(ticked.isEmpty(), "ticked in the guarded section: $ticked")
    assertEquals(true, states[lineOf("**`branch`**")])
  }

  @Test
  fun `Select Everything is read when the guarded section comes before it`() {
    // A parser that stays in the guarded section until the next class
    // heading swallows the Select Everything row between them, and the
    // editor's Select All goes dead.
    assertEquals(lineOf("**SELECT EVERYTHING**"), report.selectAll?.line)
    assertTrue(report.guarded.single().line < report.selectAll!!.line)
  }

  @Test
  fun `the guarded section is read apart, with where each field is read`() {
    val field = report.guarded.single().fields.single()

    assertEquals("minAmount", field.name)
    assertEquals(3, field.parts.size)
    assertEquals(
      listOf(Read("lib/app.dart:6", "/Users/me/app/lib/app.dart", 6)),
      field.reads,
    )
    assertEquals("lib/models/person.dart", report.guarded.single().file)
  }

  @Test
  fun `a class box never reaches the guarded section`() {
    val states = desiredStates(report, report.classes.single().line, true)

    assertEquals(false, states[report.guarded.single().fields.single().line])
  }

  @Test
  fun `ticking a guarded field ticks its parts and nothing else`() {
    val field = report.guarded.single().fields.single()
    val states = desiredStates(report, field.line, true)

    assertEquals(true, states[field.line])
    field.parts.forEach { assertEquals(true, states[it.line]) }
    assertEquals(false, states[report.selectAll!!.line])
    assertEquals(false, states[report.classes.single().line])
  }

  @Test
  fun `ticking every guarded part settles its field and nothing else`() {
    var edited = text
    for (part in report.guarded.single().fields.single().parts) {
      edited = applyStates(edited, mapOf(part.line to true))
    }
    val after = parseReport(edited)
    val last = after.guarded.single().fields.single().parts.last()
    val states = desiredStates(after, last.line, true)

    assertEquals(true, states[after.guarded.single().fields.single().line])
    assertEquals(false, states[after.selectAll!!.line])
  }

  @Test
  fun `the page is handed the guarded section and its reads`() {
    val json = report.toJson()

    assertTrue(json.contains(""""guarded":[{"name":"DepositBank""""))
    assertTrue(json.contains(""""reads":[{"label":"lib/app.dart:6""""))
  }

  @Test
  fun `an older report, with no guarded section, parses as before`() {
    val lines = text.split('\n')
    val older = (lines.take(section.first) + lines.drop(section.last + 1)).joinToString("\n")
    val parsed = parseReport(older)

    assertTrue(parsed.guarded.isEmpty())
    assertEquals(listOf("branch"), parsed.classes.flatMap { c -> c.fields.map { it.name } })
    assertEquals(lineOf("**SELECT EVERYTHING**") - section.count(), parsed.selectAll?.line)
  }
}
