# LoongPass Logo

`loongpass.svg` 是唯一设计源：蓝色圆角底、三个白色应用方块和一个勾，表示多应用与辅助签到。修改 Logo 只修改这一份 SVG，其他图片均为生成结果。

使用 CairoSVG 与 Pillow 导出应用侧栏/README PNG、macOS AppIcon 和 Windows ICO；macOS 仅额外保留系统图标画布的透明留白。无需应用运行时依赖。

CairoSVG 需要系统 Cairo 库。macOS 可通过 Homebrew 安装 `cairo`，并在下列命令前设置 `DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix cairo)/lib"`，供 uv 的 Python 环境找到该库。

```sh
uv run tool/generate_branding.py
uv run tool/generate_branding.py --website-root /path/to/LoongPass-website
uv run tool/generate_branding.py --website-root /path/to/LoongPass-website --check
```

官网 `public/icon.svg` 与 `public/icon.png` 是只读镜像，导航、页脚、favicon 和分享预览复用它们。同步时同时更新资源内容版本，避免浏览器保留旧图标。两个仓库分别提交；先推送应用仓，再推送官网仓，最后更新 workspace 指针。
