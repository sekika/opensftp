---
layout: page
title: OpenSFTP
lang: ja
permalink: /ja/
---

OpenSFTPは、macOSのSSH設定を利用して、サーバー上のファイルを閲覧・転送・管理するアプリです。ローカルのファイル操作にはFinderを使い、Finderとアプリの間でドラッグ＆ドロップしてファイルを転送できます。

主な特徴：

- macOS標準のSSH設定と公開鍵認証を利用して接続。接続先ごとの設定を別途管理する必要がありません。
- Finderに似た操作感でサーバー上のファイルを閲覧し、ドラッグ＆ドロップでアップロード・ダウンロードできます。
- 対応ファイルはアプリ内でプレビューできます。
- サーバー間のファイルコピーにも対応しています。
- SFTPを基本とし、フォルダ転送にはrsyncも選択できます。
- 複数の転送をキューで管理し、進捗や実行ログを確認できます。
- オープンソースのため、機密情報を外部に送信する処理がないことをソースコードで検証できます。

ソースコードを取得し、自分のMacでビルドして使用します。このページでは、インストールから接続設定、基本操作、トラブルシューティングまでを説明します。

![OpenSFTPのアイコン表示とPDFプレビュー]({{ '/img/screenshot.png' | relative_url }})

- [インストールと接続]({{ '/ja/installation/' | relative_url }})
- [ファイル操作]({{ '/ja/usage/' | relative_url }})
- [転送]({{ '/ja/transfers/' | relative_url }})
- [プレビュー]({{ '/ja/preview/' | relative_url }})
- [設定]({{ '/ja/configuration/' | relative_url }})
- [困ったときは]({{ '/ja/troubleshooting/' | relative_url }})

## 開発 {#開発}

このアプリは[関勝寿](https://github.com/sekika)が開発し、MITライセンスのもとで公開しています。

AIエージェントのワーキングディレクトリに本リポジトリを指定することで、各自の好みに合わせて仕様を自由に変更できます。

プルリクエストは受け付けていませんが、バグ報告や仕様変更の提案は歓迎します。[GitHubのIssues](https://github.com/sekika/opensftp/issues)に投稿してください。
