---
layout: page
title: Settings
lang: en
permalink: /configuration/
---

## Layout and saved settings

### Panels and bars

Drag the dividers between the browser, queue, and logs vertically to adjust their heights. When you hide the queue or logs, the visible panels use the space that becomes available.

Use the **View** menu to show or hide each area independently.

| Menu item | Area | On the next launch |
|---|---|---|
| Show Connection Bar | The top bar with OpenSFTP, the host field, host suggestions, and the Connect button. | Always shown. |
| Show Main Status Bar | The bottom bar with the host, execution status, Cancel, Queue, and Logs buttons. | Restores the previous state. |
| Show Folder Status Bar | The item count, selection count, and drag-and-drop guidance below the browser. | Restores the previous state. |
| Show Transfer Queue | The list of operations and their results. | Restores the previous state. |
| Show Logs | The log for the selected operation. | Restores the previous state. |

On first launch, the connection bar, both status bars, and queue are shown; logs are hidden. You can show hidden bars again from the **View** menu.

### Language

The interface supports Japanese and English. At launch, the app uses Japanese if it is the system's preferred language, and English otherwise. Choose **言語 / Language → 日本語** or **English** to change the language without restarting. On the next launch, the app selects its language from the system preferences again.

This English documentation uses the English menu names. If the interface is in Japanese, choose **言語 → English**. Filenames, paths, and raw logs are not translated.

### Resource limits {#resource-limits}

**Settings → Limits** groups limits for listings, folder operations, logs, diffs, and previews. Each setting shows its unit and default value. **Reset to Defaults** resets all of them, including preview lines per page and binary data limits. Previously saved preview settings are carried over. Connection timeout and keepalive settings are under **Settings → rsync**.

| Category | Setting | Default | Behavior at the limit |
|---|---|---|---|
| File listings | Maximum entries per folder | 100,000 entries | Invalidates the entire listing and cancels transfers or deletions that depend on it. |
| File listings | Maximum listing data | 64 MiB | Stops fetching the listing. Incomplete listings are not used. |
| Folder operations | Maximum total entries in recursive scanning | 1,000,000 entries | Cancels planning before starting transfers or deletion. |
| Folder operations | Maximum depth | 128 levels | Cancels planning before starting transfers or deletion. The selected root counts as level 1. |
| Logs and diffs | Maximum retained log data | 4 MiB | Keeps the beginning of each job's stdout and stderr separately and omits later output. Processing and progress reporting continue. |
| Logs and diffs | Maximum diff data | 8 MiB | Stops comparison and records that output was omitted. The downloaded file is kept. |
| Previews | Lines per page | 50 lines | Splits the display into pages. |
| Previews | Maximum text or extracted information | 1 MiB | Stops the preview. Text checks include the extra line used to determine whether another page exists. |
| Previews | Maximum image or video data | 5 MiB | Stops the preview if the original image or representative video frame exceeds the transfer limit. |
| Previews | Time per command | 30 seconds | Stops the command and cancels the preview. |

The total entry count includes the selected root and entries scanned at the source and destination, or at the deletion target, for planning. Skipped entries count too. Repeated listings to recheck the same folder do not add to the count. Total entry and depth limits apply to SFTP folder transfers, recursive deletion, and server-to-server copies; they do not apply to rsync's own scanning. The listing data limit measures received data, not memory usage after parsing. The validation limit for individual SFTP protocol packets and the 256-byte HexDump limit are fixed.

The retained log limit and diff data limit are separate. Even if diff output is fetched successfully, any part beyond the log retention limit is not displayed. These settings do not limit the combined size of the whole job history. Remove unneeded history from the queue.

### What is saved

| Item | Behavior on launch |
|---|---|
| Connection field value | Restored, without starting a connection. |
| List/icon view, list column widths, and hidden-file visibility | Restores the previous settings. |
| Sort field (name, kind, size, or modification time) and ascending/descending order | Restores the previous settings. The initial order is ascending by name. |
| Visibility of the queue, logs, and both status bars | Restores the previous settings. |
| Window size | Restores the size of the last window closed, or the frontmost browser when quitting the app. The initial size is 1050 × 760 points, and the default minimum is 600 × 550 points. |
| Double-click action and download destination | Restores the previous settings. |
| Settings → Limits (listings, folder operations, logs, diffs, and previews), and preview window position and size | Restores the previous settings. |
| Settings → Appearance (color scheme, minimum window size, and icon view) | Restores the previous settings. |
| Settings → rsync (rsync transfer options and SSH connection settings) | Restores the previous settings. |
| Connection bar visibility and interface language | Follows the launch rules described above. |
| Connection state, displayed folder, navigation history, selection, job history, and log contents | Not saved. |

Use **Settings → Interaction** to choose the file-open action and the destination for **Download and Open**. **Settings → Appearance** contains color scheme, minimum window size, and icon view settings. **Settings → rsync** contains rsync transfer options and SSH connection settings.

## Limitations

- The app uses your existing OpenSSH configuration, ssh-agent, and Keychain integration. It does not create keys, register them on servers, or manage passwords.
- Regular files, folders, and symbolic links are supported. Other special files are excluded from transfers.
- SFTP folder transfers, server-to-server copies, and recursive folder deletion follow the maximum depth (128 by default) and total entry limits under **Settings → Limits**. They also stop if link names are ambiguous and cannot be matched safely. These depth and entry limits do not apply to rsync's scanning.
- If another app or user changes the source or destination at the same time, the app cannot detect every conflict. There is no transfer-wide rollback.
