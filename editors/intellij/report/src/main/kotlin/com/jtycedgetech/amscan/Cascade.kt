package com.jtycedgetech.amscan

/** A single-character rewrite: the smallest edit that flips one box. */
data class BoxEdit(
  val line: Int,
  /** Column of the character between the brackets. */
  val column: Int,
  val replacement: Char,
)

/** Whether the box on [line] is ticked, or null when there is none. */
fun readBox(text: String, line: Int): Boolean? {
  val lines = text.split('\n')
  if (line < 0 || line >= lines.size) return null

  val source = lines[line]
  val open = source.indexOf('[')
  if (open == -1 || source.length < open + 3 || source[open + 2] != ']') return null

  return when (source[open + 1]) {
    ' ' -> false
    'x', 'X' -> true
    else -> null
  }
}

/**
 * The edit that puts the box on [line] into [checked], or null when it is
 * already there — so a cascade only writes what actually moves.
 */
fun setBox(text: String, line: Int, checked: Boolean): BoxEdit? {
  val current = readBox(text, line)
  if (current == null || current == checked) return null

  val open = text.split('\n')[line].indexOf('[')
  return BoxEdit(line, open + 1, if (checked) 'x' else ' ')
}

/** The edit that flips the box at [line]. */
fun toggleBox(text: String, line: Int): BoxEdit? {
  val current = readBox(text, line) ?: return null
  return setBox(text, line, !current)
}

/** Which row a box belongs to, and where it sits in the tree. */
sealed interface Located {
  data object All : Located
  data class Klass(val classIndex: Int) : Located
  data class FieldRow(val classIndex: Int, val fieldIndex: Int) : Located
  data class PartRow(val classIndex: Int, val fieldIndex: Int) : Located
}

/** Finds the box on [line], or null when that line holds none. */
fun locate(report: Report, line: Int): Located? {
  if (report.selectAll?.line == line) return Located.All

  report.classes.forEachIndexed { c, block ->
    if (block.column >= 0 && block.line == line) return Located.Klass(c)
    block.fields.forEachIndexed { f, field ->
      if (field.line == line) return Located.FieldRow(c, f)
      if (field.parts.any { it.line == line }) return Located.PartRow(c, f)
    }
  }
  return null
}

/**
 * The state every box should hold after setting the one on [line].
 *
 * Two rules, and the second follows from the first:
 *
 *  * Setting a box sets everything under it — tick a field and its parts go
 *    with it, because selecting a field means selecting all of it.
 *  * A parent is ticked exactly when all of its children are. So unticking
 *    one part unticks its field, its class and Select Everything, and ticking
 *    the last outstanding part ticks them all back.
 *
 * Deriving the parent rather than storing it is what makes the two consistent
 * by construction: there is no state in which a field is ticked while one of
 * its parts is not.
 */
fun desiredStates(report: Report, line: Int, checked: Boolean): Map<Int, Boolean> {
  val target = locate(report, line) ?: return emptyMap()

  val state = mutableMapOf<Int, Boolean>()
  for (box in allBoxes(report)) state[box.line] = box.checked

  fun setField(field: Field) {
    state[field.line] = checked
    for (part in field.parts) state[part.line] = checked
  }

  fun setClass(block: ClassBlock) {
    if (block.column >= 0) state[block.line] = checked
    block.fields.forEach(::setField)
  }

  when (target) {
    is Located.All -> {
      report.selectAll?.let { state[it.line] = checked }
      report.classes.forEach(::setClass)
    }
    is Located.Klass -> setClass(report.classes[target.classIndex])
    is Located.FieldRow ->
      setField(report.classes[target.classIndex].fields[target.fieldIndex])
    is Located.PartRow -> state[line] = checked
  }

  // Settle every parent from the bottom up. A field with no parts of its own
  // — one whose declaration could not be found — keeps whatever it was given,
  // since there is nothing beneath it to derive from.
  for (block in report.classes) {
    for (field in block.fields) {
      if (field.parts.isNotEmpty()) {
        state[field.line] = field.parts.all { state[it.line] == true }
      }
    }
    if (block.column >= 0 && block.fields.isNotEmpty()) {
      state[block.line] = block.fields.all { state[it.line] == true }
    }
  }

  report.selectAll?.let { all ->
    val tickable = report.classes.filter { it.column >= 0 }
    if (tickable.isNotEmpty()) {
      state[all.line] = tickable.all { state[it.line] == true }
    }
  }

  return state
}

/** Every box the report declares, for select-all style operations. */
fun allBoxes(report: Report): List<Box> {
  val boxes = mutableListOf<Box>()
  report.selectAll?.let { boxes.add(it) }
  for (block in report.classes) {
    if (block.column >= 0) boxes.add(block)
    for (field in block.fields) {
      boxes.add(field)
      boxes.addAll(field.parts)
    }
  }
  return boxes
}

/**
 * Applies [states] to [text]. Used by the tests, and by any caller that wants
 * the resulting document rather than a list of edits.
 */
fun applyStates(text: String, states: Map<Int, Boolean>): String {
  val lines = text.split('\n').toMutableList()
  for ((line, checked) in states) {
    val edit = setBox(lines.joinToString("\n"), line, checked) ?: continue
    val source = lines[edit.line]
    lines[edit.line] =
      source.substring(0, edit.column) + edit.replacement +
        source.substring(edit.column + 1)
  }
  return lines.joinToString("\n")
}
