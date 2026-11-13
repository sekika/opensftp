---
layout: page
title: Transfers
lang: en
permalink: /transfers/
---

## Upload and download

| Action | Steps |
|---|---|
| Upload | Select files or folders in Finder and drop them onto the OpenSFTP browser. |
| Download | Select items in OpenSFTP and drag them to the destination folder in Finder. |
| Choose a download destination | Select items, then use the download button, **Download to Finder…** from the context menu, or **Remote → Download…** to choose a destination. |

You can transfer multiple items together. Uploads go to the remote folder currently displayed. Dropping onto a folder within the listing still uploads to the currently displayed location, rather than inside that folder.

For regular-file uploads and downloads, a same-name item at execution time prompts you to choose **Overwrite**, **Save as file-1.txt**, or **Cancel**. Numbered names insert the smallest unused positive integer (1, 2, 3, …) immediately before the extension. For example, if `file-1.txt` and `file-3.txt` exist, the app saves as `file-2.txt`. Canceling stops that item while subsequent queued jobs continue. An item of a different type, such as a folder or link, cannot be overwritten. If Finder supplies a different name, that name is used as the destination.

For regular-file uploads and SFTP folder uploads, the app resolves the destination's actual path and checks that parent paths have not been replaced with links before writing and before finalizing the save. Files are transferred to exclusively created temporary files and renamed after success. If the server does not support atomic replacement of an existing file, overwriting fails and leaves the original intact. Checks and writes are separate operations, so to fully prevent path substitution, server permissions must also prevent other users from changing the destination and its parent paths. This save procedure does not apply to rsync.

When a local download is successfully saved under a numbered name, the app automatically compares the existing and newly saved files with `/usr/bin/diff -u`. For example, retaining `file.txt` and saving as `file-1.txt` runs the equivalent of `diff -u '/destination/file.txt' '/destination/file-1.txt'`. Open **Logs** and select the queue row to see the command, differences, diagnostic output, and `[diff exit: …]`. Lines beginning with `-` are from the existing file; `+` lines are from the newly saved file. This comparison is not run for uploads, overwrites, failed transfers, or canceled transfers.

Folders keep their original names. At execution time, choose a transfer method whether creating a new folder or updating an existing same-name folder. See [Folder transfers](#folder-transfers) for the choices.

Check completion or failure in the app's queue. In particular, a folder appearing in Finder during a drag download does not mean its contents have finished transferring. Do not move or rename items being transferred until the queue shows **Completed**.

## Queue, progress, and logs

### Check results in the queue

Transfers and operations are added to each window's queue. File transfers, changes, and deletions run one at a time across the app; other windows can fetch listings in parallel. Each folder transfer or deletion appears as one job per folder. A failure in one job does not stop other waiting jobs.

The queue shows the action, host and target, state, start time, and result. Use **Retry** on a failed row to try again. Retrying displays folder transfer method or deletion confirmations again. Jobs are not retried automatically.

### View progress

Long SFTP transfers show a progress bar, percentage, approximate amount transferred, speed, and estimated time remaining in the result column. These appear about one second after the first progress update, so short transfers may not show a progress bar. Speed and remaining time are estimates. Stalled or unmeasurable transfers show “—” or **Calculating**.

A 100% reading alone does not confirm success: wait for the queue state to become **Completed**.

rsync does not show a percentage, speed, or time remaining. View the running log to see the rsync command and transferred item output. For rsync operations that include deletion, result counts show only what rsync reports.

### Cancel or quit

Use **Cancel** at the bottom of the window or **Remote → Cancel** to cancel active and waiting jobs together. The menu action remains available when the main status bar is hidden.

The app prevents closing a window involved in an operation or quitting while work is in progress. Wait for completion, or cancel and wait for work to stop. Closing the last browser window quits the app.

### View logs

Open logs with the **Logs** button or **View → Show Logs**, then select a queue row. You can inspect start and finish times, exit code, result, standard output (stdout), and diagnostic output (stderr). Communication output and rsync item names are not translated when the interface language changes.

The diff for a local download saved under a different name is appended to the same log. `[diff exit: 0]` means identical contents, `1` means differences, `2` or higher means a comparison error, and `-1` means diff failed to start. A comparison error keeps the saved file and the transfer's successful state; the job's exit code remains the transfer's exit code. Binary files usually report whether they differ rather than showing content differences.

Lines that appear to contain authentication information or private-key output are masked. Logs still include hostnames, usernames, and paths, so review their contents before sharing them.

Use **Clear Finished Jobs** to remove completed, failed, or canceled jobs and their logs. There is no log-to-file export feature. Job history and log contents are lost when the app quits.

## Folder transfers

At the start of each folder job, the app checks whether a same-name destination folder exists and asks you to choose a method once. This applies to uploads, downloads, drag and drop, and retries. Server-to-server copies have different choices; see [Copy between windows](#copy-between-windows).

For a new destination folder, the three choices are **SFTP**, **rsync**, and **Cancel**. SFTP and rsync transfer the entire folder as a new folder.

For an existing same-name folder, there are five choices:

| Method | Behavior | Destination-only items |
|---|---|---|
| SFTP: Updated Files Only | Transfers new or changed files and links through SFTP. | Kept. |
| SFTP: Overwrite All | Transfers source regular files and links, overwriting same-name items of the same type. | Kept. |
| rsync | Transfers changes together using rsync. | Kept. |
| rsync --delete | Compares and transfers the whole folder with rsync, removing destination-only items. | Deleted. |
| Cancel | Cancels this folder transfer. Other waiting jobs continue. | Unchanged. |

rsync is based on `-avz -e ssh` and uses its native recursion to compare and transfer the whole folder (`rsync --delete` adds `--delete`). SSH uses `/usr/bin/ssh` with noninteractive authentication and strict host-key checking.

**`rsync --delete` deletes items. If the source is empty, it removes the destination folder's contents.** Deletion is confined to the matching destination folder being transferred. There is no undo, so check the transfer direction and destination.

Folder transfers include empty folders, hidden files, and subfolders. Hidden files are included even when hidden in the browser. Transferring into an existing folder merges contents rather than replacing the folder as a whole.

Permissions for regular files inside folders follow these rules:

| Method and direction | New file | Overwriting an existing file |
|---|---|---|
| SFTP download | Inherits remote permissions. | Keeps the existing local file's POSIX permissions. |
| SFTP upload | Inherits local permissions. | Inherits local permissions. |
| rsync / rsync --delete | Inherits source permissions. | Matches source permissions. Downloads can change existing local permissions too. |

All methods carry over source modification times. rsync preserves permissions through `-p`, which is included in `-a`. Setting these attributes can fail depending on the destination's permissions and capabilities.

### How Updated Files Only is determined

SFTP's **Updated Files Only** transfers:

- Files missing at the destination.
- Files with different source and destination sizes, even if the destination has a newer timestamp.
- Same-size files with a newer source modification time.
- Files whose timestamps cannot be determined.
- Symbolic links with different target text.

Same-size files are skipped if the destination timestamp is equal or newer. Timestamps are compared at the precision shown in the server's listing: minute precision for entries showing a time, and day precision for older entries showing only a date. Content changes within the same comparison time unit and with the same size cannot be detected. Differences between the server's and Mac's clocks or time zones also affect the decision.

With **rsync** and **rsync --delete**, rsync compares the whole folder and decides what to transfer. The SFTP rules and timestamp precision above do not apply. **rsync --delete** also removes destination-only items.

### Conflicts, failures, and cancellation

During SFTP transfers, a same-name type conflict between a file, folder, or link prompts you to skip or stop. With **rsync** and **rsync --delete**, rsync handles type conflicts inside the folder.

Failure or cancellation stops that folder's job. Already transferred items, created folders, and deleted items are not rolled back. A retry checks everything again from the beginning. There is no resume-from-interruption feature.

## Symbolic links

Opening and transferring links behave differently:

| Target | Double-click, Return, or Open | Download or upload |
|---|---|---|
| Individually selected link to a folder | Navigates to the target folder. | Transfers the target folder. |
| Individually selected link to a file | Opens the target file using the configured action. | Copies the link itself. |
| Individually selected broken link | Shows an explanation. | Copies the link itself. |
| Link inside a folder being transferred | — | Copies the link itself without following its target. |

Copying a link preserves its relative or absolute target text. If the corresponding path does not exist at the destination, the copied link may be broken. Cyclic links inside folders are copied as links without being followed.

An item confirmed as a link to a folder displays a folder icon with an arrow. Type checks run in the background, so the display can change after the initial listing. Links to files, broken links, and links of unknown type use a generic link icon.

You cannot rename or delete a link itself selected in the listing. During recursive folder deletion, nested links are deleted as links; their targets are not traversed.

## Server-to-server copies

Use **File → New Window** or `⌘N` to add a browser window. Each window can connect to a different folder on the same server or to another server. A new window starts disconnected. Its title shows the window number, host, and current folder.

Connections, navigation history, selections, and display settings are independent per window. Menus and shortcuts act on the active window. Language and SSH host suggestions are shared across all windows. Saved display settings become the defaults for new windows without changing other windows that are already open.

### Copy between windows

1. Open source and destination windows and connect each one.
2. Navigate to the destination folder in the destination window.
3. Select items in the source window and drag them onto the destination listing.
4. Check the result in the destination queue.

You can copy multiple regular files, folders, and links together. The destination is the currently displayed folder. Source items remain in place; modifier keys do not turn this into a move. The source at drag start and destination at drop time are retained, so later navigation does not change what is transferred. Involved windows cannot reconnect until the transfer finishes.

For same-name regular files and individually selected links, choose **Overwrite**, **Save as file-1.txt**, or **Cancel**. Numbered names use the smallest unused positive integer at the destination.

Folders keep their original names. If there is no same-name folder, one is created. Only an existing same-name folder prompts for **Updated Files Only**, **Overwrite All**, or **Cancel**. Updated items are new items, regular files with different sizes, and regular files whose source modification time is newer. Server-to-server copies compare SFTP modification times at second precision. Content changes with the same size and timestamp are not detected. Both update modes keep destination-only items. Nested type conflicts prompt you to skip or stop, and special files are skipped. Nested links are recreated with their original target text without following the targets. An individually selected link to a folder copies its target folder.

### Requirements and saving

Regular-file contents, including files inside folders, pass through the Mac using `scp -3`. No temporary content files or directory trees are created on the Mac. SFTP handles scanning, folder and link creation, and finalizing saved names.

Server-to-server copying requires the Mac's `/usr/bin/ssh` and `/usr/bin/scp` to be OpenSSH 9 or later, plus noninteractive SFTP access from the Mac to both endpoints. Check the OpenSSH version with `ssh -V`. If an older client cannot perform the operation, the copy stops with an error.

At the destination, each file is transferred under a temporary `.opensftp-…partial` name in the same folder. The final name is committed after verifying success, source attributes, and the transferred file's size. Standard permissions and modification times are preserved for regular files and newly created folders. If a server does not support atomic replacement of existing items, an overwrite fails while preserving the original file. This does not replace an entire folder in one step: items completed before a later failure remain in place.

With the same effective SSH connection settings, attempts to copy a folder onto itself or between a folder and its descendant are stopped. However, identity cannot be determined completely across different DNS names, users, jump-host settings, hard links, or server mount arrangements. External changes during execution cannot be fully excluded either.

Data passes through the Mac's network connection, so sleep or disconnection stops the transfer. The destination needs space for temporary files. Since scp starts separately for each regular file, copying many small files can take time.

### Queue, logs, and closing windows

The destination window shows the transfer queue, detailed logs, and prompts for name conflicts or update methods. The source shows the same job's progress and result as **Outgoing Copy (Reference)**. Select that reference row and open logs, then use **Show Destination** to switch to the window with detailed logs.

Server-to-server copies show scanning, transferring, and finalizing-save phases, along with completed/target item counts. **Cancel** on a server-to-server queue row stops the same job from either window. You can also cancel only a waiting row. The bottom-of-window or menu **Cancel** action stops that window's active jobs, waiting jobs, and transfers referenced as outgoing jobs together.

File transfers, changes, and deletions execute one at a time across the app. Other windows can fetch listings in parallel. Subsequent queued jobs continue even if a transfer fails.

A window that is the source or destination of a waiting or running job cannot be closed. Wait for completion, or cancel and wait for stopping and cleanup to finish. Unrelated windows can be closed. Closing the last browser window quits the app. `⌘Q` also prevents quitting while work is in progress.
