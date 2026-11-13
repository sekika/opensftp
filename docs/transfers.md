---
layout: page
title: Transfers
lang: en
permalink: /transfers/
---

## Upload and download

Drag files or folders from Finder onto the OpenSFTP browser to upload them to the remote folder currently displayed. To download, drag selected items into the destination in Finder, or use **Download to Finder…** from the context menu to pick a folder.

When a regular file already exists, choose to overwrite it, save under a numbered name, or cancel. For example, if `file-1.txt` and `file-3.txt` exist, the next numbered name is `file-2.txt`. When a download succeeds under a numbered name, the job log includes a unified diff against the existing file, subject to the diff and log limits. An incompatible destination type cannot be overwritten.

## Queue, progress, and logs

The queue shows the action, target, start time, state, and result. Transfers and remote mutations run one at a time across the app. Other windows can still list folders. Check the queue for completion before moving or renaming a downloaded folder in Finder.

Long SFTP transfers show estimated progress, speed, and time remaining. For rsync, use **Logs** to see command output. Select a job to inspect its log, including command output and exit status. Failed jobs can be retried from the queue. Cancel a waiting or active job with its queue action. Wait for cleanup to finish before closing an involved window.

## Folder transfers

For a new destination folder, choose SFTP or rsync when the job starts. For a folder that already exists, choose one of the following:

| Method | Behavior |
|---|---|
| SFTP, changed items only | Copies new or changed items and preserves destination-only items. |
| SFTP, overwrite all | Copies all source files and links over matching destination types and preserves destination-only items. |
| rsync | Copies changes using rsync and preserves destination-only items. |
| rsync --delete | Copies changes and removes destination-only items inside the matching folder. |
| Cancel | Skips this folder and continues with the queue. |

With `rsync --delete`, an empty source can remove all contents of the destination folder. Check the direction and destination before proceeding. Folder transfers include dotfiles, subfolders, and empty folders. An interrupted transfer can leave completed changes in place. A retry evaluates the folder from the beginning.

SFTP's changed-only mode checks for missing items, file-size differences, newer source timestamps, unknown timestamps, and different symbolic link targets. Timestamp comparisons use the precision available in the server listing. Changes with the same size and timestamp at that precision can be missed. With rsync, rsync selects what to transfer.

SFTP downloads retain existing local POSIX permissions when overwriting and inherit source permissions for new files. SFTP uploads and rsync use source permissions. File modification times are carried over where supported.

## Symbolic links

OpenSFTP distinguishes standalone selections from links encountered during a recursive copy. SFTP folder transfers and server-to-server folder copies preserve nested links and their target text. Opening a link follows its target, and selecting a folder link for a server-to-server copy copies the target folder. A relative link can resolve differently at the destination. Check it after copying.

## Server-to-server copies

Open two browser windows with `⌘N`, connect each, and browse to the source and destination. Drag selected items from the source browser to the destination browser. Confirm the result in the destination queue. This copies the items and leaves the source intact.

For a folder that already exists at the destination, choose changed items only, overwrite all, or cancel. Both copy modes retain destination-only items. Changed-only copies compare file sizes and SFTP modification times at second precision. The app confirms how to handle type conflicts during recursive copies.

Regular file contents travel through the Mac via `scp -3`. The app uses SFTP for listing, creating folders or links, and finalizing names. OpenSSH 9 or later and noninteractive SFTP access to both endpoints are required. The destination needs space for the temporary file as well as any existing copy. Keep the Mac awake and connected until the copy finishes.

The destination window shows the detailed log and prompts. The source window shows progress and offers a shortcut to the destination. Either queue row can cancel the same job. Both windows must stay open and connected until the copy and any cleanup finish.
