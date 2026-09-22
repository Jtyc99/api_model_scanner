package com.jtycedgetech.amscan

import com.intellij.openapi.editor.colors.EditorColorsManager
import com.intellij.ui.JBColor
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import java.awt.Color

/** Reads the running IDE's colours so the table matches the current theme. */
object ReportTheme {
  private fun hex(color: Color) = "#%02x%02x%02x".format(color.red, color.green, color.blue)

  private fun rgba(color: Color, alpha: Double) =
    "rgba(${color.red}, ${color.green}, ${color.blue}, $alpha)"

  fun current(): Theme {
    val scheme = EditorColorsManager.getInstance().globalScheme
    val background = UIUtil.getPanelBackground()

    return Theme(
      foreground = hex(UIUtil.getLabelForeground()),
      background = hex(background),
      border = rgba(UIUtil.getLabelForeground(), 0.22),
      inputBackground = hex(UIUtil.getTextFieldBackground()),
      hover = rgba(UIUtil.getLabelForeground(), 0.08),
      link = hex(JBUI.CurrentTheme.Link.Foreground.ENABLED),
      error = hex(JBColor.RED),
      fontFamily = "-apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif",
      monoFamily = "'${scheme.editorFontName}', monospace",
      fontSize = "${UIUtil.getLabelFont().size}px",
    )
  }
}
