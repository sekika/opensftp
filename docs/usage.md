---
layout: page
title: Browsing and file management
lang: en
permalink: /usage/
---

## Browse and open files

### Navigate folders

- Double-click a folder, or select one folder and press Return, to open it.
- Use the up arrow or `⌘↑` to go to the parent folder.
- Use the **Back** and **Forward** arrows or `⌘[` / `⌘]` to move through navigation history.
- Use **Refresh** or `⌘R` to fetch the current listing again.

If navigation fails, the existing listing and navigation history are kept. Navigation history resets when you reconnect and is not retained after quitting the app.

### Selection, views, and sorting

Command-click to add or remove items from the selection, and Shift-click to select a range. With the browser focused, press `⌘A` to select all visible items. You can also move the selection with the arrow keys and extend it with Shift-arrow.

Use the list/icon toggle or **View → Icon View** to switch views. In list view, click a column heading to sort by name, kind, size, or modification time. Click the same heading again to switch between ascending and descending order.

Regular files display the macOS icon associated with their extension, such as PDF, image, Office document, or archive icons. This works in both list and icon views. Icons can differ depending on the apps installed on your Mac.

The **Kind** column and **Get Info** show the macOS kind name obtained from the extension. Sorting by kind uses this name too. The language of kind names follows macOS settings. Files with no extension or an unregistered kind are shown as **File**. The app does not fetch file contents or extended attributes for this information.

For symbolic links, **Get Info** obtains the target through SFTP and shows its path under **Original**. Relative targets are resolved against the folder containing the link. If the target cannot be obtained, the other information is still shown.

**Get Info** displays the filename and separate fields for kind, size, host, location (the item's full path), modification date, owner, and permissions. The owner is shown as a username or numeric ID, depending on the server's listing response.

Drag the right-hand heading boundary of **Name**, **Kind**, or **Size** horizontally to resize that column. If the total column width exceeds the window width, scroll horizontally. The view mode and column widths are saved and restored on the next launch and when switching from icon view back to list view.

### Hidden files

Use the eye button, **View → Show Hidden Files**, or `⌘⇧.` to toggle items whose names begin with `.`. They are hidden on first launch; subsequent launches restore your last setting. `.` and `..` are never shown.

Hiding hidden files also clears their selection. The item count below the browser counts the currently visible items, not the total including subfolders.

### Open files {#open-files}

Use **Settings → Interaction** to choose the double-click action. Return and **Open** in the context menu follow the same setting.

| Setting | Behavior |
|---|---|
| Preview (default) | Opens a read-only [in-app preview]({{ '/preview/' | relative_url }}#preview-a-file). Requires permission to run commands over SSH. |
| Download and Open | Saves a local copy to the configured download folder (`~/Downloads` by default), then opens it in the default macOS app. |

For an SFTP-only server, choose **Download and Open**. If an item with the same name exists at the destination, choose to overwrite it, save under a numbered name, or cancel.

A file opened with **Download and Open** is a copy saved on your Mac. Editing and saving it does not automatically update the server. Upload the saved file to update the remote version.

Links to folders display a folder icon with a link arrow. Links to files display the icon for the target's extension with a link arrow. If the target cannot be determined, a generic link icon is used.

When opening a symbolic link, the app checks its target type. A folder target opens that folder; a file target opens the target file according to the **Preview** or **Download and Open** setting. A broken link or an unknown target type displays an explanation and leaves the existing listing in place.

## Manage remote files

| Action | Steps |
|---|---|
| Create a folder | Click the new-folder button or choose **Remote → New Folder…**, then enter a name. |
| Rename | Select one item, then use **Rename or Move…** in the context menu or **Remote** menu and enter a new name. |
| Move elsewhere | Use the same **Rename or Move…** action and enter an absolute destination path. |
| Delete | Select items, then use the delete button, context menu, or **Remote → Delete…**. |
| Get information | Select an item and choose **Get Info** from the context menu. |

**Deletion does not move items to the Trash and cannot be undone.** The confirmation shows the host and full paths of the targets. Deleting a nonempty folder includes all hidden files and subfolders. The server's root folder `/` cannot be deleted.

If a connection loss, permissions error, or change to a target occurs during deletion, the operation stops at that point. Items already deleted are not restored. If the app cannot verify a folder listing or link names, or the folder hierarchy is too deep, it fails before starting deletion.

## Keyboard shortcuts

`⌘` means Command and `⇧` means Shift. Browser selection and navigation shortcuts require focus in the browser.

| Key | Action |
|---|---|
| Return | Connect from the host field or open the selected item from the browser. |
| Space | Preview one selected regular file or the target of one selected link to a regular file. |
| Escape | Close the preview when it has focus. |
| Arrow keys | Move the selection. |
| Shift-arrow | Select a range. |
| `⌘N` | Open a new browser window. |
| `⌘A` | Select all visible items. |
| `⌘↑` | Go to the parent folder. |
| `⌘[` / `⌘]` | Go back or forward. |
| `⌘R` | Refresh the listing. |
| `⌘⇧N` | Create a folder. |
| `⌘Delete` | Delete the selected items after displaying a confirmation. |
| `⌘⇧.` | Toggle hidden files. |
| `⌘⇧K` | Toggle the queue. |
| `⌘⇧L` | Toggle logs. |
