---
layout: page
title: Troubleshooting
lang: en
permalink: /troubleshooting/
---

## Troubleshooting

### Xcode or XCTest errors when running make

Open the full Xcode app to finish setup, then check the active developer tools with:

```sh
xcode-select --print-path
```

If this shows `/Library/Developer/CommandLineTools` and you get an error that `XCTest` cannot be found, switch to the full Xcode app. Adjust the path if you installed Xcode elsewhere.

```sh
unset DEVELOPER_DIR
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
make
```

To select Xcode only for this Terminal command without changing the system-wide setting, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make
```

If old build artifacts cause problems after an Xcode update, run `swift package clean` at the repository root, then run `make` again.

### Terminal connects, but the app fails

Check whether a normal `sftp example` connection requires you to enter a passphrase or verification code manually. Also try the noninteractive connection command in [Set up SSH]({{ '/installation/' | relative_url }}#set-up-ssh).

An app launched from Finder can have a different ssh-agent environment from Terminal. Check which keys are loaded with:

```sh
ssh-add -l
```

To investigate the difference, quit the app and launch its executable directly from the Terminal session that can connect:

```sh
"$HOME/Applications/OpenSFTP.app/Contents/MacOS/OpenSFTP"
```

### Unknown or mismatched host key

Run `sftp example` in Terminal on the same Mac and verify the server's key. If it does not match, ask the administrator whether the server changed or you are connecting to the wrong destination. Do not delete entries from `known_hosts` without checking the cause.

### Missing host suggestions or connection timeouts

Reload suggestions after changing the configuration. Enter names from `Include` files manually. Check the hostname, port, jump host, and network settings too. The app's connection wait timeout is 15 seconds.

### rsync failures

Check that rsync is available on both the Mac and the server:

```sh
/usr/bin/rsync --version
ssh example rsync --version
```

If remote command execution is prohibited, as with an SFTP-only account, choose an SFTP transfer method. The app does not automatically switch methods after a failure. Inspect the command, output, and exit code in the app's log for details.

### Same-name errors when downloading or opening a file

For a regular file with a name conflict, choose to overwrite, save under a numbered name, or cancel. If a folder or link already has the same name, choose a different name or cancel. To update the contents of an existing folder, choose a folder transfer method.

### Finder's drop destination cannot be determined

Use the download button or **Download to Finder…** from the context menu to choose a destination. If you need to repeat the Finder action, drag the items again.

### Copying a link fails, or the copy is broken

The app does not rewrite the link's target text. Check whether the same target can be reached from the destination. When overwriting an existing link through SFTP, a server that does not support link replacement causes the operation to fail while preserving the existing link.

### A transfer failed or was canceled, or temporary items remain

Check the queue result and logs. Transfers and deletions completed before failure or cancellation remain in place. A failed upload can also leave a partially transferred file at the destination.

Downloads, regular-file and SFTP folder uploads, and server-to-server copies use temporary items whose names begin with `.opensftp-` and end with `.partial`. Normal failures clean them up, but a forced quit, OS shutdown, or connection loss can leave them on the Mac or server. If a change to a parent path is detected, temporary items that cannot be safely removed are also left in place and recorded in the log. Check that no operation is running before removing unneeded temporary items.
