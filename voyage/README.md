# Voyage（占位名）

独立的 macOS 原生养成游戏：所有 AI 工具的 token 用量变成小信使的旅行里程（1 万 token = 1 公里），它走遍世界并写信回来；而它的成长只取决于你的陪伴，不取决于用量。

- 产品设计：[docs/design.md](docs/design.md)
- 技术方案：[docs/technical.md](docs/technical.md)
- 界面示意：[docs/mockup.html](docs/mockup.html)

这是独立的 Swift 应用，不依赖 Token Monitor。

## 构建和运行

需要 macOS 14+、Apple Silicon、Xcode 和 npm。首次构建会把 tokscale 和像素字体下载到被忽略的 `.vendor/`。

```bash
scripts/build-app.sh
open build/TokenVoyage.app
```

应用只出现在菜单栏，不占 Dock。刘海显示在带刘海的屏幕上，浮窗可以拖动，两者都能在菜单栏关闭。

## 开发

```bash
swift test
```

不打开窗口、把所有界面渲染成 PNG（`TOKEN_VOYAGE_DATA_DIR` 让测试数据不进入真实旅程）：

```bash
TOKEN_VOYAGE_DATA_DIR=/tmp/voyage-data build/TokenVoyage.app/Contents/MacOS/TokenVoyage --snapshot /tmp/voyage-shots
```

Voyage Hub 尚未部署。打包配置 `Info.plist` 的 `VoyageHubURL` 留空时，城市新内容和联网解析心愿不发请求，继续使用内置内容与本机关键词。开发者可在启动应用可执行文件时设置 `TOKEN_VOYAGE_HUB_URL`（例如本地测试服务的 `http://127.0.0.1:17322`）；显式空值关闭，应用不读取 `.env`。设置中的两个联网开关默认开启，分别保存为新增的 `cityContentEnabled`、`wishResolveEnabled`。设备签名私钥只在首次签名请求时生成并存入 Keychain。客户端测试注入假 transport，不需要运行 Hub，也不会访问真实网络或生产 Keychain。

`remote-content.json` 永久保留接受过的故事和物品；请与旅程存档一起备份数据目录。现有“导出存档”仍只导出 `journey.json` / `care.json`，不包含远端物品库，跨设备恢复远端收藏暂需同时复制此文件。

世界地图由 `scripts/generate-worldmap.py` 从 npm 包 `world-atlas@2.0.2` 的 `land-50m.json`（Natural Earth 1:50m 陆地轮廓）生成，平时不需要重跑。网格为 480×200，覆盖北纬 84° 到南纬 60°；每格约 0.75° 经度、0.72° 纬度，比原来的 120×50 在两个方向各细 4 倍。约 99 KB 的内置数据能保留更多海岸线与岛屿细节，区域放大仍会呈现像素格，小于一格的岛屿不保证显示。

将该版本的 `land-50m.json` 放入被忽略的 `.vendor/world-atlas/`，在 `voyage/` 目录运行：

```bash
python3 scripts/generate-worldmap.py .vendor/world-atlas/land-50m.json Sources/VoyageCore/WorldMapData.swift
```

生成器只使用 Python 标准库；需要比较其他网格密度时可附加 `--width` 和 `--height`，输出路径可另选，避免覆盖内置地图。

重新生成城市数据：将 Natural Earth 的 `ne_10m_populated_places.dbf` 放入被忽略的 `.vendor/natural-earth/`，在项目目录运行 `swift scripts/generate-world-cities.swift`。

### 加一个角色

在 `Content/pets/` 新建 `<id>.json`，可复制现有角色文件；令 `id` 等于文件名，使用唯一的 `order`（首次打开按它排序，首个角色也是默认角色）。填写中英文默认名、蛋名和至少三条短句，默认名不超过 12 个字符；身体使用 16×16 像素，行内字符与 `egg.recolor` 都引用 `Content/sprites/palette.json`。`accessories` 保持空数组，留作以后身体与配饰的组合层；当前不会绘制配饰。无需登记角色或修改代码，运行 `swift test` 验证内容和存档兼容性。

## 第三方内容

- [tokscale](https://github.com/junhoyeo/tokscale)：MIT，构建时下载。
- [Fusion Pixel](https://github.com/TakWolf/fusion-pixel-font)：OFL，构建时下载，授权文件随应用打包。
- 地图数据：Natural Earth（公共领域），经 world-atlas 提供。
- 全球城市基础数据：[Natural Earth 1:10m Populated Places](https://www.naturalearthdata.com/downloads/10m-cultural-vectors/10m-populated-places/)（公共领域）；中文名通过 Foundation 的 Hant-Hans 转换为简体，国家和地区名称由 Foundation Locale 补全。
- 信件里的地点内容和照片来自 Wikipedia，并附来源链接。
