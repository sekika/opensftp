---
layout: page
title: Browsing and file management
lang: en
permalink: /usage/
---

## Browse and select files

Double-click a folder or select it and press Return to open it. Use the arrows in the toolbar to go up, back, or forward. Refresh the list after external changes.

Switch between list and icon views with the toolbar. In list view, click a column heading to sort by name, kind, size, or modification time, and click again to reverse the order. Drag a heading boundary to resize the name, kind, or size column. OpenSFTP uses macOS file kinds and icons based on the extension.

Command-click to add or remove items from the selection. Shift-click or Shift-arrow selects a range. Use the eye button or `⌘⇧.` to show or hide dotfiles. Hiding dotfiles also clears their selection.

## Open files

Double-click, Return, and the **Open** context menu use the action configured under **Settings → Interaction**. Choose **Preview** for a read-only [in-app preview]({{ '/preview/' | relative_url }}) or **Download and Open** to save a local copy and open it in the default macOS app. Use **Download and Open** on SFTP-only servers. The default download location is `~/Downloads`. Upload the edited copy when you want to update the remote file.

Opening a symbolic link follows its target. A link to a folder opens the folder, and a link to a file uses the configured open action. A broken or unresolved link displays an error. **Get Info** shows the remote path, type, size, modification time, owner, permissions, and the target path when available.

## Manage remote files

Use the **Remote** menu or the context menu to create folders, rename or move items, and delete items. Use **Get Info** to inspect an item first. Review the confirmation before deleting, especially when it includes a folder and its contents. Completed deletions cannot be undone from the app. Deleting a symbolic link removes the link itself.

## Keyboard shortcuts

| Key | Action |
|---|---|
| Return | Connect from the host field or open the selection from the browser. |
| Space | Preview one regular file or one link to a regular file. |
| Escape | Close a focused preview. |
| Arrow keys / Shift-arrow | Move the selection or extend it. |
| `⌘N` | Open a new browser window. |
| `⌘A` | Select all visible items in the browser. |
| `⌘↑` | Go to the parent folder. |
| `⌘[` / `⌘]` | Go back or forward. |
| `⌘R` | Refresh the listing. |
| `⌘⇧N` | Create a folder. |
| `⌘Delete` | Confirm deletion of the selected items. |
| `⌘⇧.` | Toggle hidden files. |
| `⌘⇧K` / `⌘⇧L` | Toggle the queue or logs. |
