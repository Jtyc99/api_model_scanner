package com.jtycedgetech.amscan

import com.intellij.openapi.command.WriteCommandAction
import com.intellij.openapi.editor.Document
import com.intellij.openapi.editor.event.DocumentEvent
import com.intellij.openapi.editor.event.DocumentListener
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.fileEditor.FileEditor
import com.intellij.openapi.fileEditor.FileEditorState
import com.intellij.openapi.fileEditor.OpenFileDescriptor
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.UserDataHolderBase
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.table.JBTable
import java.awt.BorderLayout
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import java.beans.PropertyChangeListener
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.ListSelectionModel
import javax.swing.table.AbstractTableModel

/**
 * Shows a report as a table of checkbox cells.
 *
 * Every toggle is a one-character edit to the same Markdown the CLI reads, so
 * this editor is a nicer way to write a file that would work just as well
 * typed by hand. Nothing is stored here that is not in the document.
 */
class ReportEditor(
  private val project: Project,
  private val file: VirtualFile,
) : UserDataHolderBase(), FileEditor {

  private val document: Document? = FileDocumentManager.getInstance().getDocument(file)

  private var rows: List<Row> = emptyList()

  private val model = object : AbstractTableModel() {
    override fun getRowCount() = rows.size
    override fun getColumnCount() = 3

    override fun getColumnName(column: Int) = when (column) {
      COLUMN_TICK -> ""
      COLUMN_LABEL -> "Field"
      else -> "Line"
    }

    override fun getColumnClass(column: Int): Class<*> =
      if (column == COLUMN_TICK) java.lang.Boolean::class.java else String::class.java

    // Only the tick is editable. The label and line are what the document
    // says, and typing over them here would mean nothing.
    override fun isCellEditable(row: Int, column: Int) =
      column == COLUMN_TICK && rows[row].boxLine >= 0

    override fun getValueAt(row: Int, column: Int): Any {
      val entry = rows[row]
      return when (column) {
        COLUMN_TICK -> entry.checked
        COLUMN_LABEL -> entry.label
        else -> entry.sourceLine?.toString() ?: ""
      }
    }

    override fun setValueAt(value: Any?, row: Int, column: Int) {
      if (column != COLUMN_TICK) return
      toggle(rows[row], value as? Boolean ?: return)
    }
  }

  private val table = JBTable(model).apply {
    setShowGrid(false)
    rowSelectionAllowed = true
    selectionModel.selectionMode = ListSelectionModel.SINGLE_SELECTION
    columnModel.getColumn(COLUMN_TICK).apply { maxWidth = 34; minWidth = 34 }
    columnModel.getColumn(COLUMN_LINE).apply { maxWidth = 70; minWidth = 50 }

    addMouseListener(object : MouseAdapter() {
      override fun mouseClicked(event: MouseEvent) {
        if (event.clickCount < 2) return
        val row = rowAtPoint(event.point).takeIf { it >= 0 } ?: return
        navigateTo(rows[row])
      }
    })
  }

  private val panel = JPanel(BorderLayout()).apply {
    add(JBScrollPane(table), BorderLayout.CENTER)
  }

  private val listener = object : DocumentListener {
    // The document is the only state, so an edit from anywhere — this table,
    // the Markdown tab beside it, or the CLI — redraws the same way.
    override fun documentChanged(event: DocumentEvent) = reload()
  }

  init {
    document?.addDocumentListener(listener, this)
    reload()
  }

  private fun reload() {
    val text = document?.text ?: file.inputStream.bufferedReader().readText()
    rows = flatten(parseReport(text))
    model.fireTableDataChanged()
  }

  /** Applies the cascade for one row, as a single undoable edit. */
  private fun toggle(row: Row, checked: Boolean) {
    val target = document ?: return
    if (row.boxLine < 0) return

    val report = parseReport(target.text)
    val states = desiredStates(report, row.boxLine, checked)

    WriteCommandAction.runWriteCommandAction(project, "Toggle Report Selection", null, {
      // Recomputed against the live text each time, so the offsets cannot go
      // stale between edits in the same batch.
      for ((line, wanted) in states) {
        val edit = setBox(target.text, line, wanted) ?: continue
        val start = target.getLineStartOffset(edit.line) + edit.column
        target.replaceString(start, start + 1, edit.replacement.toString())
      }
    })
  }

  /** Opens the Dart source a row names, at its line. */
  private fun navigateTo(row: Row) {
    val path = row.file ?: return
    val target = LocalFileSystem.getInstance().findFileByPath(path) ?: return
    // OpenFileDescriptor takes a 0-based line; the report records 1-based.
    OpenFileDescriptor(project, target, (row.sourceLine ?: 1) - 1, 0).navigate(true)
  }

  override fun getComponent(): JComponent = panel
  override fun getPreferredFocusedComponent(): JComponent = table
  override fun getName(): String = "Report"
  override fun setState(state: FileEditorState) = Unit
  override fun isModified(): Boolean = false
  override fun isValid(): Boolean = file.isValid
  override fun addPropertyChangeListener(listener: PropertyChangeListener) = Unit
  override fun removePropertyChangeListener(listener: PropertyChangeListener) = Unit
  override fun getFile(): VirtualFile = file
  override fun dispose() = Unit

  private companion object {
    const val COLUMN_TICK = 0
    const val COLUMN_LABEL = 1
    const val COLUMN_LINE = 2
  }
}
