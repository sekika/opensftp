---
layout: page
title: File previews
lang: en
permalink: /preview/
---

## Preview a file

Select one regular file or a symbolic link to one, then press Space or choose **Preview** from the context menu. Selecting another file updates the open preview. Use Escape or **Close** to dismiss it. OpenSFTP remembers the preview window's position and size.

Preview needs permission to run commands over SSH on the server. For SFTP-only accounts, use [Download and Open]({{ '/usage/' | relative_url }}#open-files).

## Supported formats

The server's `file` command detects format and encoding. Additional server commands depend on the file type.

| Type | What you can view |
|---|---|
| Text, logs, and source | Pages of text with optional line numbers and basic syntax highlighting. Uses `head`, `tail`, and `awk`. |
| Images | A scaled still image. Uses `stat` and `head`, then validates dimensions on the Mac. |
| ZIP, tar, and compressed tar | An archive listing using `unzip` or `tar`. For plain gzip, the app can also try reading the start of the decompressed text. |
| PDF | Text from the first three pages using `pdftotext`, or the first page as an image using `pdftoppm`. |
| Word (.docx) | Extracted text and document properties using `unzip`. |
| Audio and video | Metadata using `ffprobe`, plus a video frame from one second in when available using `ffmpeg`. |
| Other binary data | The first 256 bytes as hexadecimal and ASCII. |

For PDFs, OpenSFTP fetches the selected tab on demand and remembers which tab you used last. The first-page image is generated on the server with a maximum long edge of 2,048 pixels. Images are limited to 50 million pixels and 16,384 pixels per side before scaling. See [Settings]({{ '/configuration/' | relative_url }}#resource-limits) for transfer and processing limits.

## Read text in Terminal

Select one regular file and choose **Open in Terminal (less)**. The server needs SSH command execution, `file`, and `less`. The action checks the file type before opening it. It uses your SSH settings, allows interactive authentication in Terminal, and verifies the host key.

Use the arrow or page keys to scroll, `/` to search, and `q` to quit. The Terminal tab closes after successful exit and stays open after an error. This action streams the text in Terminal, independently of the app's preview limits and queue. If macOS requests automation permission, allow OpenSFTP to control Terminal under **System Settings → Privacy & Security → Automation**.
