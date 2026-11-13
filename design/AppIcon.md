# OpenSFTP アプリアイコン

生成方法: 組み込みの `image_gen` ツール。

元画像: `Sources/OpenSFTP/Resources/AppIcon.png`（1254×1254、RGBA、外周透過）。

生成プロンプト:

```text
Use case: logo-brand. Asset type: macOS desktop application icon for OpenSFTP, a secure file transfer browser. Create one polished production-ready square 1024x1024 icon, not a mockup. A sculpted blue folder with two bold opposing transfer arrows, one pointing up and one down, integrated on its front. Refined native macOS appearance, restrained dimensionality, soft highlights, clear silhouette at small sizes. A rounded-square deep navy tile with subtle blue gradient behind the folder, generous even transparent outer margins, fully transparent outside the tile. Centered composition. No text, no letters, no padlock, no watermark, no surrounding scene, no extra objects. Clean and recognizable.
```

`scripts/build-app.sh` がmacOS標準の `sips` と `iconutil` で16〜1024ピクセルのアイコンを作成し、`OpenSFTP.app/Contents/Resources/AppIcon.icns` に格納する。
