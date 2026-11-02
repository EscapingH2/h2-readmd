# 第三方声明与许可

本清单对应当前 `pubspec.lock` / Flutter 3.47.9（Dart 3.13.7）的依赖和 Windows Release 资源快照。
本项目自身许可证尚未选定；以下第三方文本保留各自版权和许可，不因本项目将来选择许可证而改变。

## 主要依赖

- Flutter、gpt_markdown 1.4.0、material_ui 1.9.0、url_launcher 6.3.3：BSD 3-Clause。
- filegate 1.10.0、window_manager 0.5.2：MIT。
- val_latex_flutter 和数学渲染相关组件：见对应完整许可证。
- 其余传递依赖、开发及测试依赖均保留完整许可，见下表。跨平台依赖出现在锁文件中并不表示 Android 已获支持。

## 实际随 Windows 程序分发的资源

- JetBrains Mono：gpt_markdown 的字体资产仍会打包，即使代码块使用系统 Consolas。
  Copyright 2020 The JetBrains Mono Project Authors；SIL Open Font License 1.1。
  [完整 OFL](licenses/fonts/JetBrainsMono-OFL.txt)，[官方来源](https://github.com/JetBrains/JetBrainsMono/blob/master/OFL.txt)。
- Latin Modern Roman / Sans / Mono / Roman Caps：val_latex_flutter 的数学字体资产。
  [随依赖提供的完整 GUST Font License](licenses/fonts/LatinModern-GUST-FONT-LICENSE.txt) 引用 LPPL 1.3c 或以后版本；
  [完整 LPPL 1.3c](licenses/fonts/LPPL-1.3c.txt)，[官方来源](https://www.latex-project.org/lppl/lppl-1-3c.txt)。
  字体随依赖原样分发，保留字体内嵌元数据中的作者与版权归属。
- Flutter Material Icons、着色器、引擎及其他汇总声明：保留 Release 原有
  `data/flutter_assets/NOTICES.Z`，并附上其[解压原文快照](licenses/FLUTTER_GENERATED_NOTICES.txt)。
- Microsoft YaHei、Consolas 通过系统字体名称调用；不随程序分发字体文件。
- Windows 文档图标通过系统 imageres.dll 路径引用；不分发系统 DLL 或提取出的系统图标。
- H2 Readmd 的 M↓ 应用图标由项目作者提供，不作为第三方图标列入本清单；其授权范围待作者确定。

## 分发与维护

构建 Release 后运行 `installer/Prepare-ReleaseNotices.ps1`，将本文件及 `licenses/` 放入 Release 根目录，
再编译 Inno Setup。现有脚本会递归收录这些文件，不改变安装、卸载或文件关联行为。
仅有 Flutter 自动生成的 NOTICES.Z 不足以替代缺失的字体许可文本。
依赖或 SDK 更新后需重新核对许可证与自动声明快照；本清单不是未来版本的自动审计。

## 完整依赖许可证

| 包 | 许可原文 |
| --- | --- |
| `args` | [完整许可](licenses/packages/args/LICENSE) |
| `async` | [完整许可](licenses/packages/async/LICENSE) |
| `boolean_selector` | [完整许可](licenses/packages/boolean_selector/LICENSE) |
| `characters` | [完整许可](licenses/packages/characters/LICENSE) |
| `clock` | [完整许可](licenses/packages/clock/LICENSE) |
| `collection` | [完整许可](licenses/packages/collection/LICENSE) |
| `cupertino_ui` | [完整许可](licenses/packages/cupertino_ui/LICENSE) |
| `fake_async` | [完整许可](licenses/packages/fake_async/LICENSE) |
| `filegate` | [完整许可](licenses/packages/filegate/LICENSE) |
| `flutter` | [完整许可](licenses/packages/flutter/LICENSE) |
| `flutter_lints` | [完整许可](licenses/packages/flutter_lints/LICENSE) |
| `flutter_localizations` | [完整许可](licenses/packages/flutter_localizations/LICENSE) |
| `flutter_svg` | [完整许可](licenses/packages/flutter_svg/LICENSE) |
| `flutter_test` | [完整许可](licenses/packages/flutter_test/LICENSE) |
| `flutter_web_plugins` | [完整许可](licenses/packages/flutter_web_plugins/LICENSE) |
| `gpt_markdown` | [完整许可](licenses/packages/gpt_markdown/LICENSE) |
| `http` | [完整许可](licenses/packages/http/LICENSE) |
| `http_parser` | [完整许可](licenses/packages/http_parser/LICENSE) |
| `intl` | [完整许可](licenses/packages/intl/LICENSE) |
| `json_annotation` | [完整许可](licenses/packages/json_annotation/LICENSE) |
| `leak_tracker` | [完整许可](licenses/packages/leak_tracker/LICENSE) |
| `leak_tracker_flutter_testing` | [完整许可](licenses/packages/leak_tracker_flutter_testing/LICENSE) |
| `leak_tracker_testing` | [完整许可](licenses/packages/leak_tracker_testing/LICENSE) |
| `lints` | [完整许可](licenses/packages/lints/LICENSE) |
| `matcher` | [完整许可](licenses/packages/matcher/LICENSE) |
| `material_color_utilities` | [完整许可](licenses/packages/material_color_utilities/LICENSE) |
| `material_ui` | [完整许可](licenses/packages/material_ui/LICENSE) |
| `meta` | [完整许可](licenses/packages/meta/LICENSE) |
| `path` | [完整许可](licenses/packages/path/LICENSE) |
| `path_parsing` | [完整许可](licenses/packages/path_parsing/LICENSE) |
| `petitparser` | [完整许可](licenses/packages/petitparser/LICENSE) |
| `plugin_platform_interface` | [完整许可](licenses/packages/plugin_platform_interface/LICENSE) |
| `screen_retriever` | [完整许可](licenses/packages/screen_retriever/LICENSE) |
| `screen_retriever_linux` | [完整许可](licenses/packages/screen_retriever_linux/LICENSE) |
| `screen_retriever_macos` | [完整许可](licenses/packages/screen_retriever_macos/LICENSE) |
| `screen_retriever_platform_interface` | [完整许可](licenses/packages/screen_retriever_platform_interface/LICENSE) |
| `screen_retriever_windows` | [完整许可](licenses/packages/screen_retriever_windows/LICENSE) |
| `sky_engine` | [完整许可](licenses/packages/sky_engine/license) |
| `source_span` | [完整许可](licenses/packages/source_span/LICENSE) |
| `stack_trace` | [完整许可](licenses/packages/stack_trace/LICENSE) |
| `stream_channel` | [完整许可](licenses/packages/stream_channel/LICENSE) |
| `string_scanner` | [完整许可](licenses/packages/string_scanner/LICENSE) |
| `term_glyph` | [完整许可](licenses/packages/term_glyph/LICENSE) |
| `test_api` | [完整许可](licenses/packages/test_api/LICENSE) |
| `typed_data` | [完整许可](licenses/packages/typed_data/LICENSE) |
| `url_launcher` | [完整许可](licenses/packages/url_launcher/LICENSE) |
| `url_launcher_android` | [完整许可](licenses/packages/url_launcher_android/LICENSE) |
| `url_launcher_ios` | [完整许可](licenses/packages/url_launcher_ios/LICENSE) |
| `url_launcher_linux` | [完整许可](licenses/packages/url_launcher_linux/LICENSE) |
| `url_launcher_macos` | [完整许可](licenses/packages/url_launcher_macos/LICENSE) |
| `url_launcher_platform_interface` | [完整许可](licenses/packages/url_launcher_platform_interface/LICENSE) |
| `url_launcher_web` | [完整许可](licenses/packages/url_launcher_web/LICENSE) |
| `url_launcher_windows` | [完整许可](licenses/packages/url_launcher_windows/LICENSE) |
| `val_highlight` | [完整许可](licenses/packages/val_highlight/LICENSE) |
| `val_highlight_flutter` | [完整许可](licenses/packages/val_highlight_flutter/LICENSE) |
| `val_latex` | [完整许可](licenses/packages/val_latex/LICENSE) |
| `val_latex_flutter` | [完整许可](licenses/packages/val_latex_flutter/LICENSE) |
| `vector_graphics` | [完整许可](licenses/packages/vector_graphics/LICENSE) |
| `vector_graphics_codec` | [完整许可](licenses/packages/vector_graphics_codec/LICENSE) |
| `vector_graphics_compiler` | [完整许可](licenses/packages/vector_graphics_compiler/LICENSE) |
| `vector_math` | [完整许可](licenses/packages/vector_math/LICENSE) |
| `vm_service` | [完整许可](licenses/packages/vm_service/LICENSE) |
| `web` | [完整许可](licenses/packages/web/LICENSE) |
| `window_manager` | [完整许可](licenses/packages/window_manager/LICENSE) |
| `xml` | [完整许可](licenses/packages/xml/LICENSE) |
