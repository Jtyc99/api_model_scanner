package com.jtycedgetech.amscan

import com.intellij.openapi.fileEditor.FileEditor
import com.intellij.openapi.fileEditor.FileEditorPolicy
import com.intellij.openapi.fileEditor.FileEditorProvider
import com.intellij.openapi.project.DumbAware
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile

/**
 * Claims the two reports `api_model_scanner` writes, and nothing else.
 *
 * Matched by name *and* by the directory holding them, so an unrelated
 * `unused_fields.md` somewhere in a project keeps its ordinary Markdown
 * editor.
 */
class ReportEditorProvider : FileEditorProvider, DumbAware {
  override fun accept(project: Project, file: VirtualFile): Boolean =
    file.name in REPORT_NAMES && file.parent?.name == REPORT_DIRECTORY

  override fun createEditor(project: Project, file: VirtualFile): FileEditor =
    ReportEditor(project, file)

  override fun getEditorTypeId(): String = "amscan-report"

  /**
   * Offered beside the Markdown editor rather than instead of it: the file is
   * ordinary Markdown, and being able to look at the raw text is the whole
   * reason nothing depends on this plugin.
   */
  override fun getPolicy(): FileEditorPolicy =
    FileEditorPolicy.PLACE_BEFORE_DEFAULT_EDITOR

  companion object {
    val REPORT_NAMES = setOf("unused_fields.md", "disabled_fields.md")
    const val REPORT_DIRECTORY = "api_model_scanner"
  }
}
