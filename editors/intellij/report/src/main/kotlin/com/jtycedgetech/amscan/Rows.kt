package com.jtycedgetech.amscan

/**
 * One line of the table.
 *
 * Flat rather than a tree, because the nesting a reader needs is carried by
 * [depth] and the table only has to draw what it is given. Everything here is
 * derived from the document — nothing is remembered between redraws.
 */
data class Row(
  val label: String,
  val checked: Boolean,
  /** Line of this row's box in the document, or -1 when it has none. */
  val boxLine: Int,
  val depth: Int,
  val file: String? = null,
  val sourceLine: Int? = null,
)

/** Flattens a report into rows, in document order. */
fun flatten(report: Report): List<Row> {
  val rows = mutableListOf<Row>()

  report.selectAll?.let {
    rows.add(Row("SELECT EVERYTHING", it.checked, it.line, 0))
  }

  for (block in report.classes) {
    // Shown even when the class has no toggle of its own, or its fields
    // would sit under no heading at all.
    rows.add(
      Row(
        label = block.name + if (block.dead) "  — dead" else "",
        checked = block.checked,
        boxLine = if (block.column >= 0) block.line else -1,
        depth = 0,
      ),
    )

    for (field in block.fields) {
      rows.add(Row("  " + field.name, field.checked, field.line, 1))
      for (part in field.parts) {
        rows.add(
          Row(
            label = "    " + part.label,
            checked = part.checked,
            boxLine = part.line,
            depth = 2,
            file = part.file,
            sourceLine = part.sourceLine,
          ),
        )
      }
    }
  }

  return rows
}
