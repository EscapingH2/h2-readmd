# H2 Readmd v1.1.0 for Windows

- Press **Ctrl+F** to find text or **Ctrl+H** to replace it. Search uses the Markdown source across all three views. You can undo a single replacement or a Replace All operation in one step.
- Saving now writes a temporary file before replacing the original. If another program changes or replaces an open file, H2 Readmd warns you before overwriting it.
- Search stays responsive in documents with many unmatched brackets. Preview highlights are more accurate in unfinished code blocks, and ambiguous matches take you to the relevant block.
- Moving the caret or changing a selection skips unnecessary page updates. While editing in source-only view, the hidden preview waits until you show it again to refresh its text and search highlights.
- Each document now has a 64 MiB soft budget for undo history. Older steps expire first. Even a very large replacement keeps its most recent undo step.
- The first theme toggle now switches away from the theme currently on screen. The Windows installer build checks the required third-party and font notices. The README now describes the current toolbar, fonts, search and save behavior.

## Known issues

- Typing and deleting can still be slow in long documents with many Windows-style (CRLF) line endings.
- With Baidu Pinyin, the candidate window can appear above the caret on first input or after switching back to the editor.
