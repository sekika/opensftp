---
layout: page
title: Troubleshooting
lang: en
permalink: /troubleshooting/
---

## Xcode or XCTest errors

Open the full Xcode app once to complete setup. Check the active developer directory with `xcode-select -p`. To choose Xcode for this build only, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make
```

If stale build artifacts cause errors after an Xcode update, run `swift package clean` and then `make` from the repository directory.

## Connection failures

Test the same host with `sftp -oBatchMode=yes -oStrictHostKeyChecking=yes example`. If a standard Terminal connection works but this command fails, check whether authentication requires a prompt and inspect loaded keys with `ssh-add -l`. Finder and Terminal can have different SSH agent environments. To test the Terminal environment, quit OpenSFTP and start the installed executable there:

```sh
"$HOME/Applications/OpenSFTP.app/Contents/MacOS/OpenSFTP"
```

For an unknown host key, verify it in Terminal before accepting it. For a mismatch, confirm the change with the server administrator. If an alias is missing from the menu, reload the host list or enter it manually. For a timeout, check the hostname, port, jump host, and network.

## rsync failures

Check that the Mac and server both have rsync. Use `/usr/bin/rsync --version` locally and `ssh example rsync --version` on the server. If the account permits SFTP only, choose an SFTP transfer method. The queue log shows the command output and exit code for a failed job.

## Download or copy problems

- If Finder's drop destination cannot be determined, use **Download to Finder…** and choose a folder.
- If a same-name item has an incompatible type, use a numbered name for a regular file or cancel. To update a same-name folder, choose a folder transfer method.
- If a copied symbolic link is broken, verify that its target text resolves from the destination.
- If a transfer stops, inspect the queue and logs. Completed transfers and deletions can remain in place. An abrupt stop can leave items named `.opensftp-….partial` on the Mac or server. Check that no job is using them before removing them.

OpenSFTP handles regular files, folders, and symbolic links. Concurrent changes to source or destination may go undetected. There is no transfer-wide rollback.
