# Tokotoko 待做需求分工

公开发布前还没做的需求，按“会改到哪些文件”分成两组，两个人各领一组，尽量不碰同一个文件。需求本身的定义见[产品设计](design.md)，这里只写归属和边界。

- **A 组：发行与收费**
- **B 组：内容与玩法**

## A 组：发行与收费

| 需求 | 主要改动的地方 |
|---|---|
| Developer ID 签名和公证、Bundle ID、是否支持 Intel | `scripts/build-app.sh` |
| 自动更新 | 新文件，加打包脚本 |
| 在线内容包（下载、验签） | `RemoteContentStore.swift`、`HubClient.swift`、`hub/` |
| 试用、授权码、付费墙，见[买断与试用](design.md#买断与试用) | 新文件，加 `SettingsView.swift` 和 `HomeView.swift` 的主按钮 |
| “导出存档”包含 `remote-content.json`、存档迁移和备份测试 | `SaveArchivePanels.swift`、`SaveStore.swift` |
| 隐私政策、第三方许可和 Wikipedia 署名、Open-Meteo 和额度接口的条款确认 | 文档和设置页 |

## B 组：内容与玩法

| 需求 | 主要改动的地方 |
|---|---|
| 城市资料逐条核对来源、给还没有故事的城市补内容 | `Content/` 下的数据文件 |
| 邮友等隐藏的二级页面 | `CollectionViews.swift`、`Navigation.swift` |
| 旅人身份和外观 | `Sprites.swift`、`Content/pets/`、`CareEngine.swift` |
| 把一个强时刻提前到第 6–7 个陪伴日 | `CareEngine.swift`、内容文件 |
| 连游、一次带几件、选城参数 | `Journey.swift`、`DestinationPicker.swift` |
| 家乡用系统定位预选 | `OnboardingFlow.swift` |
| 分享图、桌面小部件 | 新文件 |
| 本机模型写短句的样本验证 | 独立验证，不进主代码 |

## 两组都会碰到的地方

### `AppModel.swift` 和 `Journey.swift`

出发和结算都在这两个文件里。A 的付费墙要拦“出门”，B 的连游也要改出发逻辑。

- 这两个文件归 B。
- A 需要“能否出门”和“能否产生新信”两个判断，默认放行。这两个判断点共用一个钩子，由 B 加，或者在两组开工前由一个人先单独提交；之后 A 只在自己的新文件里实现判断，不再改这两个文件。
- 判断钩子已提供：`JourneyGate` 默认放行，提供 `allowsDeparture(at:)` 和 `allowsNewMail(at:)`，A 从自己的新文件向 `AppModel.journeyGate` 提供判断，不再改这两个文件。

### `Localizable.xcstrings`

所有界面文字都在这一个文件里。

- 两组各用自己的键名前缀。
- 每天合并一次主干，不要攒着。

### 存档

- 试用和授权绑定设备、存在 Keychain，A 不需要改存档结构。
- 存档结构和迁移（`JourneyMigrations.swift`）只归 B。
- 导出包的打包格式只归 A。

### 内容包

- A 做下载和验签的管道，不改 `Content/` 里的数据。
- B 改数据，不改 `manifest.json` 的格式。

### `SettingsView.swift`

归 A。B 组里“常驻样式有哪几种”需要加设置项，排到 A 的授权入口合并之后再做。

### `design.md`

各改各自需求对应的章节；[待确认](design.md#待确认)里的条目定下来后，由提出的人挪到“已确认的决定”。

## 开工前要先定的

这些不是开发任务，但会卡住对应的组。

| 卡谁 | 要定什么 |
|---|---|
| A | 定价；用哪家代收款服务；一份授权能激活几台 Mac；是否支持 Intel；正式名的重名和商标查重 |
| B | 已定，见[已确认的决定](design.md#已确认的决定)：不连游、一次带一件、选城参数放本机、买断用户不显示品牌合作 |

## 不占开发人手的

“M1 跑满两周、第 3 封信时说得出它学会了什么、存档没丢过”靠试用反馈验收，两个人都顺手记录。
