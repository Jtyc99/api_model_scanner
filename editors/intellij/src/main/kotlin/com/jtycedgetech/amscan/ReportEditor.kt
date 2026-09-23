package com.jtycedgetech.amscan

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.command.WriteCommandAction
import com.intellij.openapi.editor.Document
import com.intellij.openapi.editor.event.DocumentEvent
import com.intellij.openapi.editor.event.DocumentListener
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.fileEditor.FileEditor
import com.intellij.openapi.fileEditor.FileEditorManager
import com.intellij.openapi.fileEditor.FileEditorState
import com.intellij.openapi.fileEditor.OpenFileDescriptor
import com.intellij.openapi.fileEditor.impl.text.TextEditorProvider
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Disposer
import com.intellij.openapi.util.UserDataHolderBase
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.ui.jcef.JBCefApp
import com.intellij.ui.jcef.JBCefBrowser
import com.intellij.ui.jcef.JBCefBrowserBase
import com.intellij.ui.jcef.JBCefJSQuery
import java.beans.PropertyChangeListener
import javax.swing.JComponent
import javax.swing.JLabel
import javax.swing.SwingConstants

/**
 * Shows a report as a real table with checkbox cells.
 *
 * Drawn in the IDE's embedded browser rather than a Swing table, because the
 * layout that makes the report readable — a class cell spanning its fields'
 * rows, a field cell spanning its parts' — is a `rowspan`, and `JTable` has
 * no equivalent. It also means this and the VS Code editor render from one
 * piece of markup, so they cannot drift apart visually.
 *
 * Every toggle is a one-character edit to the same Markdown the CLI reads.
 * The document is the only state: an edit made in the Markdown tab beside
 * this one, or by the CLI, redraws the table the same way.
 */
class ReportEditor(
  private val project: Project,
  private val file: VirtualFile,
) : UserDataHolderBase(), FileEditor {

  private val document: Document? = FileDocumentManager.getInstance().getDocument(file)

  private val browser: JBCefBrowser? =
    if (JBCefApp.isSupported()) JBCefBrowser() else null

  private val bridge: JBCefJSQuery? =
    browser?.let { JBCefJSQuery.create(it as JBCefBrowserBase) }

  /**
   * Shown only when the IDE has no embedded browser to draw into.
   *
   * Says how to get one back, because "no embedded browser" is a dead end to
   * anyone who did not know the table was drawn in one. JCEF is missing for
   * one of two reasons — it is switched off, or the IDE boots on a runtime
   * built without it — and the fix differs, so both are named rather than
   * guessed at.
   */
  private val unavailable = JLabel(
    "<html><p style='padding:16px'>This IDE has no embedded browser, so the " +
      "table cannot be drawn.<br>The report is ordinary Markdown — use the " +
      "Markdown tab beside this one: the checkboxes work there, and the CLI " +
      "reads the same file either way." +
      "<br><br>To draw the table here, turn on " +
      "<code>ide.browser.jcef.enabled</code> in Help &rarr; Find Action " +
      "&rarr; Registry, then restart. If it is already on, this IDE is " +
      "running on a Java runtime built without JCEF — Help &rarr; Find " +
      "Action &rarr; Choose Boot Java Runtime for the IDE, and pick a " +
      "JetBrains Runtime.</p></html>",
    SwingConstants.LEFT,
  )

  private val documentListener = object : DocumentListener {
    override fun documentChanged(event: DocumentEvent) = push()
  }

  init {
    browser?.let { Disposer.register(this, it) }
    bridge?.let { Disposer.register(this, it) }

    bridge?.addHandler { raw ->
      handle(raw)
      null
    }

    browser?.let { view ->
      // Everything the page needs is in the page: the report it should draw
      // and the call that reaches back here. Nothing is injected after load,
      // because an injection that does not land leaves a blank tab with no
      // error anywhere — which is exactly what happened.
      view.loadHTML(
        renderHtml(
          theme = ReportTheme.current(),
          initialJson = currentJson(),
          bridge = bridge!!.inject("message"),
        ),
      )
    }

    document?.addDocumentListener(documentListener, this)
  }

  private fun currentJson(): String {
    val text = document?.text
      ?: runCatching { file.inputStream.bufferedReader().readText() }.getOrNull()
      ?: return "{\"classes\":[]}"
    return parseReport(text).toJson()
  }

  /** Sends the current document to the table. */
  private fun push() {
    val view = browser ?: return

    ApplicationManager.getApplication().invokeLater {
      view.cefBrowser.executeJavaScript(
        "window.__amscanUpdate && window.__amscanUpdate(${jsonString(currentJson())});",
        view.cefBrowser.url ?: "",
        0,
      )
    }
  }

  /** Handles one message from the table. */
  private fun handle(raw: String) {
    val message = parseMessage(raw) ?: return

    ApplicationManager.getApplication().invokeLater {
      when (message.type) {
        "set" -> {
          val line = message.line ?: return@invokeLater
          setSelection(line, message.checked)
        }
        "open" -> openSource(message.file ?: return@invokeLater, message.line)
        "openAsText" -> openAsText()
      }
    }
  }

  /** Applies the cascade for one row, as a single undoable edit. */
  private fun setSelection(line: Int, checked: Boolean) {
    val target = document ?: return
    val states = desiredStates(parseReport(target.text), line, checked)
    if (states.isEmpty()) return

    WriteCommandAction.runWriteCommandAction(project, "Change Report Selection", null, {
      // Recomputed against the live text each time, so offsets cannot go
      // stale between edits in the same batch.
      for ((at, wanted) in states) {
        val edit = setBox(target.text, at, wanted) ?: continue
        val start = target.getLineStartOffset(edit.line) + edit.column
        target.replaceString(start, start + 1, edit.replacement.toString())
      }
    })
  }

  private fun openSource(path: String, line: Int?) {
    val target = LocalFileSystem.getInstance().findFileByPath(path) ?: return
    // OpenFileDescriptor takes a 0-based line; the report records 1-based.
    OpenFileDescriptor(project, target, ((line ?: 1) - 1).coerceAtLeast(0), 0)
      .navigate(true)
  }

  /** Opens the same file in the plain text editor, beside this tab. */
  private fun openAsText() {
    val manager = FileEditorManager.getInstance(project)
    manager.openFile(file, true)
    manager.setSelectedEditor(file, TextEditorProvider.getInstance().editorTypeId)
  }

  override fun getComponent(): JComponent = browser?.component ?: unavailable
  override fun getPreferredFocusedComponent(): JComponent? = browser?.component
  override fun getName(): String = "Report"
  override fun setState(state: FileEditorState) = Unit
  override fun isModified(): Boolean = false
  override fun isValid(): Boolean = file.isValid
  override fun addPropertyChangeListener(listener: PropertyChangeListener) = Unit
  override fun removePropertyChangeListener(listener: PropertyChangeListener) = Unit
  override fun getFile(): VirtualFile = file
  override fun dispose() = Unit
}
