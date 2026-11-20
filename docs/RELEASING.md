# 文库 Android 构建

此分支提供「文库」本地 Android 阅读器。目前版本为 v1.0.0，构建号为 8，包名为 `org.mewx.wenku8_flutter.wenku_local`。独立包名允许和上游「轻小说文库」同时安装，书库与阅读记录分别保存。

## 代码与功能改动

- `lib/book_import_limits.dart`、`lib/local_book_archive.dart` 和 EPUB 导入及读取调用点移除了单本 EPUB 的 512 MiB 文件大小限制，将 EPUB 的累计解压上限设为 2 GiB。导入阶段检查压缩包结构和所读取的条目，普通插图在读取时校验。
- `lib/local_document_input.dart` 将关联文件改为按范围读取。大 EPUB 可以从安卓文件选择器授权后直接读取，也能按需加载插图。
- Android 的 `BookImportQueue.kt`、`BookDocuments.kt` 和 `BookTextLinks.kt` 使用原生 SHA-256。复制模式在创建应用内副本的同一遍读取中计算指纹，导入成功后直接保存已经复制好的临时文件。关联模式对已授权的文件描述符计算相同的指纹。
- `lib/pages.dart` 和 `lib/main.dart` 将首页导航改为「本地」和「我的」，默认显示本地书库。
- `android/app/build.gradle.kts` 和 `pubspec.yaml` 配置应用名称、独立包名与版本。

在同一台 Android 模拟器上，以约 1.25 GB 的 EPUB 测量从选中文件到导入完成的耗时。关联模式从约 36 秒降到 17 秒，复制模式从约 61 秒降到 26 秒。两种方式均导入 130 章并打开首章正文。

## 含音视频的 EPUB

EPUB 中保留的音视频资源可以超过单个条目的 40 MiB 上限。导入、目录读取、封面重建和插图读取使用相同规则。正文及其他普通条目的上限仍为 40 MiB，整本书累计解压上限仍为 2 GiB。

已用含约 79 MiB MOV 视频的原始 EPUB 验证，成功导入 25 章和索引 1421 个图片资源，读取了首章正文及一张插图。Android 模拟器通过文件选择器导入并打开首章。普通与恢复两条解析路径均通过大媒体兼容和大小限制回归测试。

## 快捷书签与图标

选中文字后点「书签」会直接使用「划线＋蔷薇」保存。重复保存同一选区会复用已有书签，并保留已有批注。

启动时直接进入本地书库，自动更新说明已关闭。Android 图标使用提供的 zlibrary-epub-reader-pdf-icons 素材，覆盖普通、圆形和自适应图标，应用内品牌图使用同包的 512 像素素材。

## 本地构建

验证环境使用 Flutter 3.41.9、JDK 17、Android SDK 35 和 36、NDK 28.2.13676358 及 CMake 3.22.1。

```sh
flutter pub get --enforce-lockfile
flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64
```

APK 生成在 `build/app/outputs/flutter-apk/app-release.apk`。覆盖安装此分支旧版时，沿用相同的应用签名。正式构建的签名配置通过本地 `android/key.properties` 提供。

## 公开源码与许可

Android 本地构建所需的导入、报告、听书和小组件文件来自同项目的公开快照。此分支的功能范围为本地阅读，原发行版的在线组件由上游发行版提供。[公开快照](https://github.com/Myfel1ne/Wenku8_Flutter/tree/1f54fa09f6aba16f810d47e77caa76235d519e0d)

```sh
python3 tools/check_public_source.py --revision "$(git rev-parse HEAD)"
```

公开 CI 检查提交中的公开文件清单及敏感内容。许可与署名见 `LICENSE`、`NOTICE`、`assets/licenses/` 和各第三方组件目录。
