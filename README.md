# H2 Readmd

轻量级、本地运行的 Markdown 阅读与编辑器，适合粘贴 ChatGPT 回答、编辑 Markdown 和阅读长文档。
当前发布目标为 **1.0.0，正式支持 Windows x64**。Android 仅为未来计划，当前仓库没有 Android 工程或可用 APK。

## 功能

- Markdown 源码编辑和实时预览：标题、列表、引用、GFM 表格、只读任务清单、代码高亮、图片和 LaTeX 数学公式。
- 分栏、纯编辑和纯预览视图；分栏宽度可拖动调整；两侧独立滚动。
- UTF-8 `.md` / `.markdown` 文件打开、保存及另存为；编辑器支持 Ctrl+V 和右键粘贴。
- Windows“新建”和“打开”在独立进程窗口中处理，原窗口保持自己的文档和保存状态。
- 未保存星号、动态窗口标题，以及关闭前的保存／不保存／取消提醒。
- 浅色和深色主题，中文正文使用系统微软雅黑，代码使用系统 Consolas。
- 安装程序注册 `.md` 的可选打开程序，支持 Windows 传入文件路径和内部 `--open-file` 参数。

没有账号、云同步、AI API、广告或笔记库；文档保存在用户选择的本地位置。
网络图片需要联网，点击网页链接会调用外部浏览器。

## Windows 安装和卸载

使用发布附件中的 `H2Readmd-Setup-1.0.0-x64.exe` 安装（仓库发布地址待建立后补充）。
默认安装到 `C:\Program Files\H2 Readmd`，需要管理员确认。
安装创建开始菜单快捷方式；桌面快捷方式可选，默认不勾选；完成后可选择立即启动。

通过 Windows“设置 → 应用 → 已安装的应用”卸载 H2 Readmd。
卸载移除安装文件和快捷方式，不递归删除用户自行保存的 Markdown 文件。

若使用解压后的 Release 目录，请保留 EXE 同目录的全部 DLL、`data` 和第三方声明，不能只复制 EXE。

## 使用

在左侧输入或粘贴 Markdown，右侧实时更新。顶部中间切换分栏／编辑／预览；拖动中线改变宽度。
右侧按钮可新建、打开、保存；“更多”包含另存为、主题切换及恢复默认布局。
新建和打开会创建新窗口。每个窗口单独保存；星号表示内容与已保存版本不同。

文件关联不会由安装程序强制设为默认。安装后在“设置 → 应用 → 默认应用”选择 H2 Readmd 处理 `.md`。
独立文档 ProgID 为 `H2Readmd.Markdown`，文档图标引用 Windows 通用文档图标，应用自身仍用 M↓ Logo。
已有 `md_auto_file` 或 `Applications\H2Readmd.exe` 用户关联可能仍显示应用 Logo；这不表示打开命令失效。
安装包不会更改受保护的 UserChoice，也不包含针对某台电脑的注册表修复。

## 开发环境

参考环境：Windows x64、Flutter **3.47.9 stable**、Dart **3.13.7**、Visual Studio Community 2022
（Desktop development with C++、Windows SDK 和 CMake 工具）、Inno Setup 6（已用 6.7.4 编译安装脚本）。
当前 `pubspec.lock` 的组合要求 Flutter >=3.47.0、Dart >=3.13.0；建议先使用上述参考版本。
`pubspec.yaml` 的宽泛 SDK 下限不代表当前锁定依赖能在所有旧 SDK 上构建。
Windows 开发不需要 Android Studio 或 Android SDK。

项目目录建议使用较短路径，避免 Windows 构建工具的路径长度限制。

## 源码获取和构建

仓库地址尚未建立。建立后将下面占位地址替换为真实地址；本地已有源码可跳过克隆步骤。

```powershell
git clone <实际仓库地址> h2-readmd
cd h2-readmd
flutter pub get
flutter doctor -v
flutter analyze
flutter test
flutter build windows --release
```

Release 程序为 `build\windows\x64\runner\Release\H2Readmd.exe`。
仓库已包含定制 Windows 工程，不需要重新运行 `flutter create`。

### 开发运行

内部 CMake target 保持 `markdown_reader`，`OUTPUT_NAME` 将 EXE 命名为 `H2Readmd.exe`。
当前 Flutter SDK 的常规 `flutter run -d windows` 按内部名称查找 `markdown_reader.exe`，可能构建后无法启动。
可先构建 Debug，然后直接启动实际文件：

```powershell
flutter build windows --debug
& ".\build\windows\x64\runner\Debug\H2Readmd.exe"
```

需要热重载或热重启时，可在第二个终端执行 `flutter attach -d windows`，连接刚启动的 Debug 进程。
多个实例可能需要选择或明确指定 VM Service 地址；attach 连接仍需在开发电脑验证。
没有连接调试工具时，改代码后重新构建并启动。原生 CMake、版本资源和图标修改必须重新构建。

## 测试

```powershell
flutter analyze
flutter test
```

测试包括文档初始状态、实时预览、未保存标记和启动参数（位置路径、空格、中文、`--open-file`）。
Widget 测试模拟窗口插件，不替代真实系统文件对话框、窗口关闭、默认程序或安装卸载测试。

手动测试建议：打开 `sample/renderer_check.md` 检查表格、嵌套列表、任务清单、代码、中文和公式；
测试粘贴、编辑、保存、另存为、重新打开，多窗口独立性，以及关闭时保存／不保存／取消。
通过 Windows 默认应用打开含中文和空格的 `.md` 文件，并检查文件名和内容。
检查三种视图、分栏拖动、滚动条和浅深色主题。

## Inno Setup 打包

项目版本为 `1.0.0+1`，安装程序版本为 `1.0.0`；Windows 文件版本由 Flutter 版本宏生成。
先退出旧程序，构建 Release，并补入第三方许可文本：

```powershell
flutter build windows --release
& ".\installer\Prepare-ReleaseNotices.ps1"
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" ".\installer\H2Readmd.iss"
```

也可在 Inno Setup Compiler 打开 `installer/H2Readmd.iss` 后编译。
输出为 `dist/H2Readmd-Setup-1.0.0-x64.exe`；脚本使用相对路径，递归打包整个 Release 目录。
每次重新构建后都需重新执行声明复制步骤。分发前检查版本、安装、启动、文件关联和卸载。
安装脚本的 ProgID 与卸载规则只管理本程序注册项，不强制改变默认应用。

## 已知限制

- 目前仅支持 Windows；Android 尚未适配和验收。
- 不支持同步滚动，也不处理多个窗口同时编辑同一文件的冲突。
- 相对路径本地图片尚未接入文档目录解析；网络图片依赖网络。
- 渲染依赖 gpt_markdown，不承诺完整支持所有 HTML 和 CommonMark 边缘语法。
- 部分历史环境中 Flutter 检查受进程权限限制；源码修改和语法检查不能等同于完整测试通过。
- 文件关联图标由 Windows 当前选用的 ProgID 决定，选择相同应用名称不一定切换了 ProgID。
- 当前无自动更新；Release 构建和安装包仍需人工验收。

## 第三方与项目许可证

完整依赖和随包字体声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 及 `licenses/`。
保留 Flutter 的 `data/flutter_assets/NOTICES.Z`；补充的许可文本也应随安装包分发。
第三方组件与字体各自遵守原许可证，不统一改为 MIT。

Windows 版权署名为 IKN Software Studio。项目自身许可证及应用图标授权范围尚待作者确认，目前未添加项目 LICENSE。
