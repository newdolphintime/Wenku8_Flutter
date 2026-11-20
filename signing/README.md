# Android 签名恢复

此目录保存文库 Android 发行签名的加密备份。备份包含 PKCS12 密钥库及可跨机器使用的 Gradle 签名配置，使用 AES-256-CBC 和 PBKDF2 加密，迭代次数为 600000。解密密码通过独立文件提供给仓库所有者。

另一台机器安装 OpenSSL、Bash 和项目构建工具后，在仓库根目录运行以下命令，并在提示时输入解密密码。

```sh
bash scripts/restore_android_signing.sh
flutter pub get --enforce-lockfile
flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64
```

恢复脚本生成 `android/wenku-release.p12` 和 `android/key.properties`，权限设为仅当前用户可读写。配置使用相对路径。目标文件已经存在时，脚本会停止。

此签名用于包名 `org.mewx.wenku8_flutter.wenku_local`。证书 SHA-256 为 `da20237058e040edebc6564cf3ffad66ca95ef04526835dd6e186c5bc4632693`，与当前发出的文库 APK 一致。后续构建提高 `pubspec.yaml` 的构建号即可覆盖更新。
