package com.jtycedgetech.amscan

import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The page has to stand on its own: a first paint that waits for a call from
 * the IDE is a first paint that can silently never happen.
 */
class HtmlTest {
  private val theme = Theme(
    foreground = "#fff", background = "#000", border = "#333",
    inputBackground = "#111", hover = "#222", link = "#8ab", error = "#f55",
    fontFamily = "sans-serif", monoFamily = "monospace", fontSize = "13px",
  )

  @Test
  fun `the report is in the page, not fetched after load`() {
    val report = parseReport("## Order\n\n- [ ] **`currency`**\n")
    val html = renderHtml(theme, initialJson = report.toJson())

    assertTrue(html.contains(""""name":"Order""""))
    assertTrue(html.contains("render();"), "it draws itself on load")
  }

  @Test
  fun `the bridge is written in rather than injected later`() {
    val html = renderHtml(theme, bridge = "window.cefQuery({request: message});")

    assertTrue(html.contains("window.cefQuery({request: message});"))
  }

  @Test
  fun `an empty report still yields a usable page`() {
    val html = renderHtml(theme)

    assertTrue(html.contains("<table") || html.contains("createElement('table')"))
    assertTrue(html.contains("Select All"))
  }

  @Test
  fun `the theme's colours reach the stylesheet`() {
    assertTrue(renderHtml(theme).contains("#8ab"))
  }
}
