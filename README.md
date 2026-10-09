# PicCompress（图片压缩）

一个原生 macOS 的批量图片压缩工具，SwiftUI 写的，不依赖任何第三方库或云端服务——全部在本机完成。

A native macOS batch image compressor built with SwiftUI. No third-party dependencies, no cloud upload — everything runs locally.

## 功能

- **按画质 / 按目标体积压缩**：五档预设（无损保真 / 高质量 / 均衡 / 小巧 / 极致），也可以自定义质量数值或直接给一个目标体积（如 500KB、1.2MB），程序会自动找到合适的质量参数。
- **批量处理**：选文件、拖拽、或扫描整个文件夹（可选保留原始目录结构）。
- **输出方式**：旁边建新文件夹 / 原文件加后缀 / 指定输出目录 / 直接替换原图（只有确实变小才会替换）。
- **格式转换**：保持原格式，或统一转成 JPEG / HEIC。
- **尺寸限制**：可选的最长边像素限制。
- **元数据控制**：是否保留拍摄信息（EXIF/GPS），是否保留原文件时间戳。
- **调色（可选）**：基于 `.cube` LUT 的色彩分级 —— 加载/烘焙/导出 LUT，曝光、对比度、色温、饱和度、暗部等旋钮，支持 sRGB / linear / Rec.709 三种工作色彩空间。
- **画质对比**：压缩前后并排比对。
- **访达「快速操作」**：右键图片或文件夹直接压缩（走命令行模式，默认不替换原图，更安全）。
- **命令行模式**：`PicCompress --cli` 提供和界面完全对应的参数，方便写脚本批处理。

> 这个项目早期版本还做过"读取/写回 macOS 照片图库"的功能，2026 年 9 月已经整块移除——现在只处理磁盘上的文件，不碰 Photos 图库。

## 环境要求

- macOS 13 (Ventura) 或更新
- Swift 6 工具链（随 Xcode 16 或 [Swift.org 的工具链安装包](https://www.swift.org/install/) 提供）

## 构建

```bash
# 编译 + 打包成可双击运行的 PicCompress.app（会在 dist/ 下生成）
./build.sh

# 或者只编译可执行文件，不打包 app bundle
swift build -c release
```

`build.sh` 用临时签名（`codesign --sign -`）给 app 签名，不是 Apple 开发者证书签的，所以第一次打开时 Gatekeeper 可能会拦一下：在「系统设置 → 隐私与安全性」里允许一次，或者右键 → 打开。

图标生成用到的 `Scripts/make-icon.swift` 是开发时用的脚本，没有收进这个仓库；没有它 `build.sh` 会跳过自定义图标，用系统默认图标，不影响正常使用。

## 命令行用法

```
PicCompress --cli [选项] <图片或文件夹> ...

压缩目标
  --level <档位>       pristine / high / balanced / small / extreme
  --quality <0.3-1.0>  直接指定质量
  --target <体积>      压到指定体积以内，如 500KB、1.2MB

输出
  --dest <目录>        输出到指定文件夹（默认：图片旁的 Compressed）
  --suffix             原目录生成 xxx_compressed 副本
  --in-place           直接替换原图（只有确实变小才替换）
  --structure          保留原始子目录结构
  --format <格式>      keep / jpeg / heic
  --max <像素>         限制最长边，0 表示不限制

更多参数（调色、元数据、时间戳等）见 --help。
```

## 项目结构

```
Package.swift            Swift Package 定义
build.sh                 编译 + 打包脚本
Sources/
  CZlib/                 zlib 的 C 封装（给 PNG 优化用）
  PicCompress/            App 主体：界面、压缩引擎、调色引擎、设置等
```

## License

[MIT](LICENSE)
