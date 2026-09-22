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

  /** Shown only when the IDE has no embedded browser to draw into. */
  private val unavailable = JLabel(
    "<html><p style='padding:16px'>This IDE has no embedded browser, so the " +
      "table cannot be drawn.<br>The report is ordinary Markdown — use the " +
      "Markdown tab beside this one.</p></html>",
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
      // The bridge is injected under the name the markup calls, so the same
      // script works here and in VS Code, where it is `postMessage`.
      view.jbCefClient.addLoadHandler(
        object : org.cef.handler.CefLoadHandlerAdapter() {
          override fun onLoadEnd(
            cefBrowser: org.cef.browser.CefBrowser?,
            frame: org.cef.browser.CefFrame?,
            httpStatusCode: Int,
          ) {
            val call = bridge!!.inject("message")
            cefBrowser?.executeJavaScript(
              "window.__amscanSend = function (message) { $call };",
              cefBrowser.url,
              0,
            )
            push()
          }
        },
        view.cefBrowser,
      )

      view.loadHTML(renderHtml(ReportTheme.current()))
    }

    document?.addDocumentListener(documentListener, this)
  }

  /** Sends the current document to the table. */
  private fun push() {
    val view = browser ?: return
    val text = document?.text ?: return
    val json = parseReport(text).toJson()

    ApplicationManager.getApplication().invokeLater {
      view.cefBrowser.executeJavaScript(
        "window.__amscanUpdate && window.__amscanUpdate(${jsonString(json)});",
        view.cefBrowser.url,
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
