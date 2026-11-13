---
layout: page
title: Settings
lang: en
permalink: /configuration/
---

## Layout and language

Drag the dividers between the browser, queue, and logs to resize the panels. Use **View** to toggle the connection bar, status bars, queue, and logs. The connection bar is always shown on launch. OpenSFTP restores the other panel visibility settings, browser view and column widths, sorting, hidden-file setting, and window size.

Choose **Language → English** or **Language → 日本語** to switch immediately. At launch the app uses Japanese when it is the system's preferred language and English otherwise.

## Interaction and rsync

Use **Settings → Interaction** to select what happens when you open a remote file and where **Download and Open** saves it. **Appearance** holds color, minimum window size, and icon view settings. Use the **rsync** settings to adjust transfer options, SSH connection timeout, and keepalive.

OpenSFTP saves the last entered host and your settings. Connections, current remote folders, navigation history, selections, queue entries, and logs are session-only. Authentication uses your existing OpenSSH configuration, ssh-agent, or Keychain integration.

## Resource limits

Use **Settings → Limits** to view or adjust these defaults:

| Limit | Default |
|---|---:|
| Entries per folder listing | 100,000 |
| Folder listing output | 64 MiB |
| Entries in recursive planning | 1,000,000 |
| Recursive depth, counting the selected root | 128 |
| Retained output per job stream | 4 MiB |
| Diff output | 8 MiB |
| Preview lines per page | 50 |
| Preview text or extracted information | 1 MiB |
| Preview image or video frame data | 5 MiB |
| Time per preview command | 30 seconds |

The recursive item and depth limits apply to SFTP folder transfers, recursive deletion, and server-to-server copies. rsync manages its own recursion. The log limit applies separately to standard output and standard error. The diff limit can stop comparison while keeping the downloaded file.
