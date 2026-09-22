package com.jtycedgetech.amscan

/**
 * Reads an api_model_scanner report.
 *
 * The file this parses is the same Markdown the Dart CLI writes and reads
 * back, and the shapes below mirror `lib/src/cache/selection.dart` and
 * `editors/vscode/src/report.ts` exactly. Identity is structural — a `##`
 * heading names the class, an unindented task item names a field, and
 * indented task items are that field's parts in order — so nothing is hidden
 * in the document and the parsers cannot drift on anything invisible.
 *
 * Deliberately free of any IntelliJ import: everything here is a pure
 * function over text, which is what makes it testable without an IDE host.
 */

/** A `- [x]` / `- [ ]` box, located precisely enough to rewrite in place. */
interface Box {
  val checked: Boolean

  /** 0-based line in the document. */
  val line: Int

  /** Column of the `[` on that line, or -1 when the row has no box. */
  val column: Int
}

data class SimpleBox(
  override val checked: Boolean,
  override val line: Int,
  override val column: Int,
) : Box

data class Part(
  val label: String,
  override val checked: Boolean,
  override val line: Int,
  override val column: Int,
  /** Absolute path of the Dart file, from the row's `vscode://` link. */
  val file: String? = null,
  /** 1-based line in that Dart file. */
  val sourceLine: Int? = null,
) : Box

data class Field(
  val name: String,
  override val checked: Boolean,
  override val line: Int,
  override val column: Int,
  val parts: MutableList<Part> = mutableListOf(),
) : Box

data class ClassBlock(
  val name: String,
  override val checked: Boolean,
  override val line: Int,
  override val column: Int,
  /** Path as written in the class header, relative to the report. */
  val file: String? = null,
  val dead: Boolean = false,
  val fields: MutableList<Field> = mutableListOf(),
) : Box

data class Report(
  val title: String,
  val summary: String? = null,
  val selectAll: SimpleBox? = null,
  val classes: List<ClassBlock> = emptyList(),
)

private val HEADING = Regex("""^#{2}\s+(.+?)\s*$""")
private val SELECT_ALL = Regex("""^\s*-\s*\[([ xX])]\s*\*\*SELECT EVERYTHING\*\*""")
private val CLASS_TOGGLE = Regex("""^-\s*\[([ xX])]\s*\*\*All of\s*`([^`]+)`\*\*""")
private val FIELD = Regex("""^-\s*\[([ xX])]\s*\*\*`([^`]+)`\*\*""")
private val PART = Regex("""^\s+-\s*\[([ xX])]\s*`([^`]*)`""")
private val CLASS_FILE = Regex("""^└\s*\[([^]]+)]""")
private val VSCODE_LINK = Regex("""]\(vscode://file([^:)]+):(\d+):\d+\)""")
private val SUMMARY = Regex("""^\*\*\d+ fields?\*\*""")

private fun ticked(box: String) = box.lowercase() == "x"

/** Column of the `[` in a task item, so only the box itself gets rewritten. */
private fun boxColumn(line: String) = line.indexOf('[')

/**
 * Parses a report into classes, fields and parts.
 *
 * Unrecognised lines are ignored rather than rejected: the report carries
 * prose, rules and a dead-class callout, and none of it is selectable.
 */
fun parseReport(text: String): Report {
  val lines = text.split('\n')

  var title = "API Model Scanner report"
  var summary: String? = null
  var selectAll: SimpleBox? = null
  val classes = mutableListOf<ClassBlock>()

  var currentClass: ClassBlock? = null
  var currentField: Field? = null

  // A class is rebuilt rather than mutated when its own box or file turns up
  // on a later line, because the heading comes before both.
  fun replaceClass(updated: ClassBlock) {
    classes[classes.lastIndex] = updated
    currentClass = updated
  }

  for ((i, line) in lines.withIndex()) {
    if (line.startsWith("# ")) {
      title = line.substring(2).trim()
      continue
    }

    if (summary == null && SUMMARY.containsMatchIn(line)) {
      summary = line.replace("**", "").trim()
      continue
    }

    val heading = HEADING.find(line)
    if (heading != null) {
      val block = ClassBlock(
        name = heading.groupValues[1],
        checked = false,
        line = i,
        column = -1,
      )
      classes.add(block)
      currentClass = block
      currentField = null
      continue
    }

    val open = currentClass
    if (open != null) {
      val file = CLASS_FILE.find(line)
      if (file != null) {
        replaceClass(open.copy(file = file.groupValues[1]))
        continue
      }
      if (line.startsWith("> 💀")) {
        replaceClass(open.copy(dead = true))
        continue
      }
    }

    val all = SELECT_ALL.find(line)
    if (all != null) {
      selectAll = SimpleBox(ticked(all.groupValues[1]), i, boxColumn(line))
      continue
    }

    // Before FIELD: `**All of \`X\`**` would not match FIELD anyway, since
    // that needs a backtick straight after `**` — but order makes it certain.
    val classToggle = CLASS_TOGGLE.find(line)
    if (classToggle != null && currentClass != null) {
      replaceClass(
        currentClass!!.copy(
          checked = ticked(classToggle.groupValues[1]),
          line = i,
          column = boxColumn(line),
        ),
      )
      continue
    }

    val field = FIELD.find(line)
    if (field != null && currentClass != null) {
      val entry = Field(
        name = field.groupValues[2],
        checked = ticked(field.groupValues[1]),
        line = i,
        column = boxColumn(line),
      )
      currentClass!!.fields.add(entry)
      currentField = entry
      continue
    }

    val part = PART.find(line)
    if (part != null && currentField != null) {
      val link = VSCODE_LINK.find(line)
      currentField!!.parts.add(
        Part(
          label = part.groupValues[2].trim(),
          checked = ticked(part.groupValues[1]),
          line = i,
          column = boxColumn(line),
          file = link?.groupValues?.get(1),
          sourceLine = link?.groupValues?.get(2)?.toIntOrNull(),
        ),
      )
    }
  }

  return Report(title = title, summary = summary, selectAll = selectAll, classes = classes)
}
