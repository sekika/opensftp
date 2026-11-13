---
layout: page
title: Installation and connection
lang: en
permalink: /installation/
---

## Requirements

- An Apple Silicon or Intel Mac with macOS 13 or later.
- Xcode 15 or later, compatible with your macOS version. Install the full Xcode app for XCTest.
- An SFTP account that supports public-key authentication.
- OpenSSH 9 or later on the Mac for [server-to-server copies]({{ '/transfers/' | relative_url }}#server-to-server-copies). Check with `ssh -V`.
- For rsync folder transfers, rsync on both ends and permission to run commands over SSH on the server.

## Build and install

1. Install and open Xcode to accept its license and finish setup.
2. Copy and run all three lines below together in Terminal to clone the source, enter the repository directory, and build and install the app:

```sh
git clone https://github.com/sekika/opensftp.git
cd opensftp
make
```

`make` runs the tests before building and installing the app. If the tests pass, it creates `~/Applications/OpenSFTP.app`. Open the app in Finder or run:

```sh
open "$HOME/Applications/OpenSFTP.app"
```

OpenSFTP has no version numbers. The latest source code on [GitHub](https://github.com/sekika/opensftp) is always the current version.

Choose **OpenSFTP → About OpenSFTP** to see the commit ID and date for a build made from a Git checkout. If the source has no Git history, the dialog shows “Commit information is unavailable.”

To update, quit OpenSFTP, update the source, and run `make` again. Your saved settings carry over. The default build targets your Mac's architecture. Run `UNIVERSAL=1 make` to build for both Apple Silicon and Intel.

## Set up SSH

Add a host alias to `~/.ssh/config` if you do not already have one. Use the server details and key provided for your account.

```sshconfig
Host example
    HostName sftp.example.com
    User yourname
    IdentityFile ~/.ssh/id_ed25519
    # Port 2222
    # ProxyJump bastion
```

Run `sftp example` in Terminal. On the first connection, verify the server's host key before accepting it. Type `bye` to exit. If your key has a passphrase, make it available through ssh-agent or macOS Keychain integration. For example, run `ssh-add ~/.ssh/id_ed25519` to load an existing key into the agent.

Check that the same host works without prompts:

```sh
sftp -oBatchMode=yes -oStrictHostKeyChecking=yes example
```

The connection bar requires noninteractive authentication and a known, matching host key. Set up your key and host trust in Terminal before using the app.

## Connect

Choose a host or enter one in the connection bar, then click **Connect** or press Return. OpenSFTP starts in the remote home folder. The field accepts an SSH host alias, a hostname, `user@host`, or `user@[IPv6]`. Configure ports and jump hosts in SSH config.

The host menu lists literal `Host` names directly in `~/.ssh/config`. Type names from included files manually. OpenSSH still uses its full configuration. Reload the host list after editing the file. OpenSFTP remembers the last entry and waits for you to connect on the next launch. To switch hosts, wait for active work to finish before connecting again.

## Uninstall or reset

Quit the app and move `~/Applications/OpenSFTP.app` to the Trash. To also clear saved OpenSFTP preferences, run the following while the app is closed:

```sh
defaults delete local.opensftp.desktop
```
