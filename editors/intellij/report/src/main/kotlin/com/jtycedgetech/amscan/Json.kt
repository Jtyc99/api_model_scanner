package com.jtycedgetech.amscan

/**
 * Serialises a report into the exact shape `editors/vscode/src/report.ts`
 * produces, so one piece of rendering JavaScript can draw both editors.
 *
 * Hand-rolled rather than pulled from a library: the shape is four small
 * records, and a plugin should not carry a JSON dependency into an IDE that
 * already has several of its own.
 */
fun jsonString(value: String): String {
  val out = StringBuilder("\"")
  for (c in value) {
    when (c) {
      '"' -> out.append("\\\"")
      '\\' -> out.append("\\\\")
      '\n' -> out.append("\\n")
      '\r' -> out.append("\\r")
      '\t' -> out.append("\\t")
      else ->
        if (c < ' ') out.append("\\u%04x".format(c.code)) else out.append(c)
    }
  }
  return out.append("\"").toString()
}

private fun jsonOrNull(value: String?) = value?.let(::jsonString) ?: "null"

private fun Part.toJson() = buildString {
  append("{")
  append(""""label":${jsonString(label)},""")
  append(""""checked":$checked,""")
  append(""""line":$line,""")
  append(""""column":$column,""")
  append(""""file":${jsonOrNull(file)},""")
  append(""""sourceLine":${sourceLine ?: "null"}""")
  append("}")
}

private fun Field.toJson() = buildString {
  append("{")
  append(""""name":${jsonString(name)},""")
  append(""""checked":$checked,""")
  append(""""line":$line,""")
  append(""""column":$column,""")
  append(""""parts":[${parts.joinToString(",") { it.toJson() }}]""")
  append("}")
}

private fun ClassBlock.toJson() = buildString {
  append("{")
  append(""""name":${jsonString(name)},""")
  append(""""checked":$checked,""")
  append(""""line":$line,""")
  append(""""column":$column,""")
  append(""""file":${jsonOrNull(file)},""")
  append(""""dead":$dead,""")
  append(""""fields":[${fields.joinToString(",") { it.toJson() }}]""")
  append("}")
}

private fun SimpleBox.toJson() =
  """{"checked":$checked,"line":$line,"column":$column}"""

fun Report.toJson(): String = buildString {
  append("{")
  append(""""title":${jsonString(title)},""")
  append(""""summary":${jsonOrNull(summary)},""")
  append(""""selectAll":${selectAll?.toJson() ?: "null"},""")
  append(""""classes":[${classes.joinToString(",") { it.toJson() }}]""")
  append("}")
}
