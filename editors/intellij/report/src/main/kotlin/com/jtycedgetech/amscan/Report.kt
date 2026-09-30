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

/** Somewhere a field of this name is read through a `dynamic` receiver. */
data class Read(
  /** As the report writes it, e.g. `lib/app.dart:6`. */
  val label: String,
  val file: String? = null,
  /** 1-based. */
  val sourceLine: Int? = null,
)

data class Field(
  val name: String,
  override val checked: Boolean,
  override val line: Int,
  override val column: Int,
  val parts: MutableList<Part> = mutableListOf(),
  /** Set only on fields in the guarded section. */
  val reads: List<Read> = emptyList(),
  /**
   * The disabled report's rows: code that was commented out, listed without
   * checkboxes because a field moves back whole or not at all.
   */
  val snippets: MutableList<String> = mutableListOf(),
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
  /**
   * Fields that look unused but are read through `dynamic` somewhere, so
   * removing one compiles and then throws. Kept out of [classes] on purpose:
   * nothing that cascades — Select Everything, a class box — ever reaches
   * them. Only a tick on the field or one of its parts does.
   */
  val guarded: List<ClassBlock> = emptyList(),
  /** The headings the report gives each section, when it gives them. */
  val guardedTitle: String? = null,
  val mainTitle: String? = null,
  /** The first paragraph under the guarded section's heading. */
  val guardedNote: String? = null,
)

private val HEADING = Regex("""^#{2}\s+(.+?)\s*$""")
private val SELECT_ALL = Regex("""^\s*-\s*\[([ xX])]\s*\*\*SELECT EVERYTHING\*\*""")
private val CLASS_TOGGLE = Regex("""^-\s*\[([ xX])]\s*\*\*All of\s*`([^`]+)`\*\*""")
private val FIELD = Regex("""^-\s*\[([ xX])]\s*\*\*`([^`]+)`\*\*""")
private val PART = Regex("""^\s+-\s*\[([ xX])]\s*`([^`]*)`""")
private val CLASS_FILE = Regex("""^└\s*\[([^]]+)]""")
// The CLI writes whichever of these the editor in use understands, so both
// have to be read: a report made in Android Studio carries no `vscode://`
// link at all, and reading only that left every Line cell empty.
private val VSCODE_LINK = Regex("""]\(vscode://file([^:)]+):(\d+):\d+\)""")
private val JETBRAINS_LINK =
  Regex("""]\(https?://[^/)]*/api/file([^:)]+):(\d+)\)""")
private val SUMMARY = Regex("""^\*\*\d+ fields?\*\*""")

// The guarded section is written in shapes the patterns above do not match —
// `###`, `*` bullets, `Declared in` — so an editor released before it existed
// cannot take its rows for ordinary ones and tick them from Select Everything.
private val GUARDED_HEADING = Regex("""^#{3}\s+(.+?)\s*$""")
private val GUARDED_FILE = Regex("""^Declared in \[([^]]+)]""")
private val GUARDED_FIELD = Regex("""^\*\s*\[([ xX])]\s*\*\*`([^`]+)`\*\*""")
private val GUARDED_PART = Regex("""^\s+\*\s*\[([ xX])]\s*`([^`]*)`""")
private val READ_VSCODE = Regex("""\[([^]]+)]\(vscode://file([^:)]+):(\d+):\d+\)""")
private val READ_JETBRAINS =
  Regex("""\[([^]]+)]\(https?://[^/)]*/api/file([^:)]+):(\d+)\)""")
// A line that is nothing but bold text heads a section: the CLI words it for
// the report it is writing, so the editor shows that rather than guessing.
private val BANNER = Regex("""^\*\*([^*].*?)\*\*\s*$""")
// A disabled field's code, one line per commented-out range, with no box.
private val SNIPPET = Regex("""^\s+[-*]\s+`(.*)`\s*$""")

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
  val guarded = mutableListOf<ClassBlock>()

  var currentClass: ClassBlock? = null
  var currentField: Field? = null
  var inGuarded = false
  // A heading waits here until the section it names begins.
  var banner: String? = null
  var note: String? = null
  var awaitingNote = false
  var guardedTitle: String? = null
  var guardedNote: String? = null
  var mainTitle: String? = null

  fun snippetOf(line: String): Boolean {
    val snippet = SNIPPET.find(line) ?: return false
    val field = currentField ?: return false
    field.snippets.add(snippet.groupValues[1])
    return true
  }

  // A class is rebuilt rather than mutated when its own box or file turns up
  // on a later line, because the heading comes before both.
  fun replaceClass(updated: ClassBlock) {
    val into = if (inGuarded) guarded else classes
    into[into.lastIndex] = updated
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

    // Read before anything that depends on the section: the guarded section
    // sits above it, and Select Everything is what closes that section.
    val all = SELECT_ALL.find(line)
    if (all != null) {
      selectAll = SimpleBox(ticked(all.groupValues[1]), i, boxColumn(line))
      inGuarded = false
      currentClass = null
      currentField = null
      if (banner != null && mainTitle == null) mainTitle = banner
      banner = null
      // The main table has no note to wait for.
      awaitingNote = false
      continue
    }

    // Also ahead of the guarded section's own lines: the main table's heading
    // sits between that section and Select Everything.
    val bannerLine = BANNER.find(line)
    if (bannerLine != null) {
      banner = bannerLine.groupValues[1].trim()
      note = null
      awaitingNote = true
      continue
    }
    if (awaitingNote && line.isNotBlank() && !line.startsWith("#") &&
      !line.startsWith("---")
    ) {
      note = line.replace("`", "").trim()
      awaitingNote = false
      continue
    }

    val heading = HEADING.find(line)
    val guardedHeading = if (heading == null) GUARDED_HEADING.find(line) else null
    if (heading != null || guardedHeading != null) {
      inGuarded = guardedHeading != null
      awaitingNote = false
      if (inGuarded && guardedTitle == null && banner != null) {
        guardedTitle = banner
        guardedNote = note
        banner = null
      }
      val block = ClassBlock(
        name = (heading ?: guardedHeading)!!.groupValues[1],
        checked = false,
        line = i,
        column = -1,
      )
      (if (inGuarded) guarded else classes).add(block)
      currentClass = block
      currentField = null
      continue
    }

    val guardedClass = currentClass
    if (inGuarded && guardedClass != null) {
      val file = GUARDED_FILE.find(line)
      if (file != null) {
        replaceClass(guardedClass.copy(file = file.groupValues[1]))
        continue
      }

      val field = GUARDED_FIELD.find(line)
      if (field != null) {
        val reads = (READ_VSCODE.findAll(line) + READ_JETBRAINS.findAll(line))
          .sortedBy { it.range.first }
          .map {
            Read(
              label = it.groupValues[1],
              file = decodePath(it.groupValues[2]),
              sourceLine = it.groupValues[3].toIntOrNull(),
            )
          }
          .toList()
        val entry = Field(
          name = field.groupValues[2],
          checked = ticked(field.groupValues[1]),
          line = i,
          column = boxColumn(line),
          reads = reads,
        )
        guardedClass.fields.add(entry)
        currentField = entry
        continue
      }

      if (snippetOf(line)) continue

      val part = GUARDED_PART.find(line)
      if (part != null && currentField != null) {
        val link = VSCODE_LINK.find(line) ?: JETBRAINS_LINK.find(line)
        currentField!!.parts.add(
          Part(
            label = part.groupValues[2].trim(),
            checked = ticked(part.groupValues[1]),
            line = i,
            column = boxColumn(line),
            file = link?.groupValues?.get(1)?.let(::decodePath),
            sourceLine = link?.groupValues?.get(2)?.toIntOrNull(),
          ),
        )
      }
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
      val link = VSCODE_LINK.find(line) ?: JETBRAINS_LINK.find(line)
      currentField!!.parts.add(
        Part(
          label = part.groupValues[2].trim(),
          checked = ticked(part.groupValues[1]),
          line = i,
          column = boxColumn(line),
          // The CLI percent-encodes the path, so a directory with a space in
          // it reaches the filesystem as it is actually spelled.
          file = link?.groupValues?.get(1)?.let(::decodePath),
          sourceLine = link?.groupValues?.get(2)?.toIntOrNull(),
        ),
      )
      continue
    }

    snippetOf(line)
  }

  return Report(
    title = title,
    summary = summary,
    selectAll = selectAll,
    classes = classes,
    guarded = guarded,
    guardedTitle = guardedTitle,
    mainTitle = mainTitle,
    guardedNote = guardedNote,
  )
}

/// Undoes the percent-encoding the CLI applies to a path in a link.
///
/// The escapes are UTF-8 bytes, so they are gathered as bytes and decoded
/// together: turning each `%XX` into a character on its own reads `项目` as
/// `é¡¹ç®`, and every link under a folder named in anything but ASCII
/// pointed at a path that does not exist. Hand-rolled to keep this module
/// free of any platform dependency.
fun decodePath(encoded: String): String {
  if (!encoded.contains('%')) {
    return encoded
  }
  val bytes = ArrayList<Byte>(encoded.length)
  var i = 0
  while (i < encoded.length) {
    val c = encoded[i]
    if (c == '%' && i + 2 < encoded.length) {
      val code = encoded.substring(i + 1, i + 3).toIntOrNull(16)
      if (code != null) {
        bytes.add(code.toByte())
        i += 3
        continue
      }
    }
    for (b in c.toString().encodeToByteArray()) bytes.add(b)
    i++
  }
  return bytes.toByteArray().decodeToString()
}
