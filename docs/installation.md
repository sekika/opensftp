---
layout: page
title: Installation and connection
lang: en
permalink: /installation/
---

## Installation and updates

### Requirements

- An Apple Silicon or Intel Mac with macOS 13 or later.
- Xcode 15 or later, compatible with your macOS version.
- OpenSSH 9 or later on the Mac for server-to-server copies. Check with `ssh -V`.
- An SFTP server that supports SSH public-key authentication, and the connection details for your account.

`make` runs tests before building the app. The tests use XCTest, so install the full Xcode app. An environment with only Command Line Tools may not be able to build the tests.

SFTP connections and transfers use the SSH and SFTP tools included with macOS. To use rsync for folder transfers between Finder and OpenSFTP, rsync must be available on both the Mac and the server, and the server must allow commands over SSH. For an SFTP-only server, choose an SFTP transfer method.

### Build and install

1. Install Xcode and open it once to accept its license and install any additional components.
2. Copy and run all three lines below together in Terminal. They download the source, enter the repository directory, and build and install the app.

```sh
git clone https://github.com/sekika/opensftp.git
cd opensftp
make
```

After the tests pass, the app is built and installed at:

```text
~/Applications/OpenSFTP.app
```

`~` means your home folder. The destination is `Applications` (plural), which is created automatically if it does not exist. The app is installed inside your home folder rather than in the system-wide `/Applications` folder.

Open `OpenSFTP.app` in Finder, or run:

```sh
open "$HOME/Applications/OpenSFTP.app"
```

If the build fails, see [Troubleshooting]({{ '/troubleshooting/' | relative_url }}). If the tests fail, `make` stops there and does not build or update the app.

After building the app, you can delete the cloned repository folder if you no longer need the source. The installed app will continue to work. Download the source again when you want to update it.

### Update

OpenSFTP has no version numbers. The latest source code on [GitHub](https://github.com/sekika/opensftp) is always the current version.

Choose **OpenSFTP → About OpenSFTP** to see the commit ID and date for a build made from a Git checkout. If the source has no Git history, the dialog shows “Commit information is unavailable.”

Quit OpenSFTP, update the source, and run `make` again in the same directory. This updates the existing `~/Applications/OpenSFTP.app`. Saved display settings and the connection field's value carry over.

By default, the build targets the Mac you are using. To build an app that supports both Apple Silicon and Intel, run:

```sh
UNIVERSAL=1 make
```

## Set up SSH

### Prepare your SSH configuration

Check the server hostname, username, port, and key to use, and configure them in `~/.ssh/config`. If you need to register your public key on the server, follow the server administrator's instructions.

Here is an example. Replace the values with those for your server.

```sshconfig
Host example
    HostName sftp.example.com
    User yourname
    IdentityFile ~/.ssh/id_ed25519
    # For a nonstandard port
    # Port 2222
    # For a jump host
    # ProxyJump bastion
```

In this example, `example` is the connection name you select or enter in the app. If you already have a working SSH configuration and key, you can use them as they are.

### Verify the connection in Terminal

Before using the app, connect from Terminal on the same Mac:

```sh
sftp example
```

If the first connection asks you to confirm the host key, verify that it is the correct key for the server before accepting it. Once connected, enter `bye` to exit.

If your key has a passphrase, make it available to the app through ssh-agent or macOS Keychain integration. For example, add an existing key to ssh-agent with:

```sh
ssh-add ~/.ssh/id_ed25519
```

Then check that you can connect without interactive input:

```sh
sftp -oBatchMode=yes -oStrictHostKeyChecking=yes example
```

OpenSFTP has no screen for entering passwords, key passphrases, or verification codes. Authentication methods that require this input on every connection cannot be used. The app does not ask you to confirm a host key on first connection either: it stops the connection if the key is unknown or does not match.

Authentication uses your existing OpenSSH configuration, ssh-agent, and Keychain integration. OpenSFTP does not store passwords, private-key contents, or passphrases.

### Host suggestions

The app's host menu lists concrete `Host` names written directly in `~/.ssh/config`. After changing the file, reload the list from the host field's menu or **Connection → Reload Host List**.

Wildcard `Host` entries, negated patterns, and `Match` conditions do not produce suggestions. Names in files referenced by `Include` do not appear in the menu either; enter those names manually. The connection itself still follows OpenSSH settings, including `Include`, `ProxyJump`, ports, and keys.

## Connect

1. Launch the app.
2. Select a suggestion or enter a connection name in the field at the top.
3. Click **Connect** or press Return in the connection field.
4. Once connected, the server's home folder appears.

The field accepts an SSH configuration alias, a hostname, `user@host`, or `user@[IPv6]`. It does not accept URLs, `host:path`, strings containing port numbers, options, or whitespace. Set ports and other connection options in `~/.ssh/config`.

The connection field's value is saved. On the next launch, only the name is restored; the app does not connect automatically. Click **Connect** or press Return to start the connection.

To switch hosts, change the field and click **Connect**. You cannot change the connection while an operation is running.

## Uninstall or reset

Quit the app and move `~/Applications/OpenSFTP.app` to the Trash in Finder. You can also delete the cloned repository folder separately if you no longer need the source.

To reset display settings, saved connection entries, and other OpenSFTP preferences, quit the app and run:

```sh
defaults delete local.opensftp.desktop
```

This deletes OpenSFTP's saved settings. It does not delete `~/.ssh/config`, SSH keys, `known_hosts`, or files you have transferred.
