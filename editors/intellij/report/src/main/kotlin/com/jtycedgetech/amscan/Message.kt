package com.jtycedgetech.amscan

/** One instruction from the table: tick something, or open something. */
data class ReportMessage(
  val type: String,
  val line: Int? = null,
  val checked: Boolean = false,
  val file: String? = null,
)

/**
 * Reads a message from the table.
 *
 * A deliberately small reader rather than a JSON library: these messages have
 * four known keys and are produced by markup in this same repository, so the
 * job is to read those keys and ignore anything else — including anything
 * malformed, which is dropped rather than thrown, since a bad message should
 * never take the editor down.
 */
fun parseMessage(raw: String): ReportMessage? {
  val type = stringField(raw, "type") ?: return null
  return ReportMessage(
    type = type,
    line = intField(raw, "line"),
    checked = boolField(raw, "checked") ?: false,
    file = stringField(raw, "file"),
  )
}

private fun stringField(raw: String, key: String): String? {
  val at = raw.indexOf("\"$key\"")
  if (at < 0) return null

  val colon = raw.indexOf(':', at + key.length + 2)
  if (colon < 0) return null

  val open = raw.indexOf('"', colon + 1)
  if (open < 0) return null

  val value = StringBuilder()
  var i = open + 1
  while (i < raw.length) {
    when (val c = raw[i]) {
      '\\' -> {
        if (i + 1 >= raw.length) return null
        when (val escaped = raw[i + 1]) {
          'n' -> value.append('\n')
          'r' -> value.append('\r')
          't' -> value.append('\t')
          else -> value.append(escaped)
        }
        i += 2
      }
      '"' -> return value.toString()
      else -> {
        value.append(c)
        i++
      }
    }
  }
  return null
}

private fun intField(raw: String, key: String): Int? {
  val match = Regex("\"$key\"\\s*:\\s*(-?\\d+)").find(raw) ?: return null
  return match.groupValues[1].toIntOrNull()
}

private fun boolField(raw: String, key: String): Boolean? {
  val match = Regex("\"$key\"\\s*:\\s*(true|false)").find(raw) ?: return null
  return match.groupValues[1] == "true"
}
