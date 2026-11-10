# Voyage 技术方案

## 实现交接

新会话从这里开始。产品规则以 [design.md](design.md) 为准，界面以 [mockup.html](mockup.html) 为准。实现位于 `voyage/`，与根目录应用独立。

### 当前代码和设计的差距

| 位置 | 现状 | 要改成 |
|---|---|---|
| `LetterComposer` | M0 模板渲染旧信 | 新信用内容包的正文，旧信继续用模板 |
| `JourneyState` | 已实现五个状态、路费、小时补算和夜航兜底（v8） | [一趟旅行](#一趟旅行)；相关界面改版另见下列各项 |
| `PixelMap` | 画路线连线，标停靠点、目的地和当前位置；整张世界地图，120×50 格，约 3° 一格 | 只标家、现在位置、路过的位置，不画连线；旅途页和刘海用区域视图。现有网格放大后海岸线太粗，要用 `scripts/generate-worldmap.py` 重新生成更细的地图 |
| `RoomArt`、`HomeView` | 房间里始终画着宠物；一周七天画成房间下方地板上的踏砖 | 不在家时房间里没有宠物，状态写它在哪；地板换成包裹、脚印、地毯、松动的地板和木箱，踏砖不再使用 |
| 护照、`Footprints` | 路线和足迹已只统计到站停留；护照仍为国家印章界面 | 护照只列停留过的城市 |
| `LetterNotifications`、设置 | 有“到达新国家”通知和开关 | 删除；出发和到站只在刘海提示 |
| `WishContent`、`LocalWishModel` | 本机关键词加本机模型解析 | 服务端解析，失败退回本机关键词；首个心愿预置 |
| 刘海 | 只在带刘海的屏幕显示 | 待发预告和倒计时；外接屏显示顶部居中的小条 |
| 服务端 | 没有 | [Voyage Hub](#voyage-hub内容心愿和同城偶遇规划) |

下文凡是标“已实现”的段落，以及[引擎不变量](#引擎不变量)、[养成引擎](#养成引擎m1-起)里关于里程、航段、下一站和心愿解析的描述，说的都是现在的代码，改版完成时一并改写。

### 改版开发顺序

每一步都能单独构建、测试和提交。

1. **里程口径和系数（已实现）：** 全部 token 按去程 100 万 token/km 推进，回程 10 万 token/km 常量已定义；Journey v7 保存累计公里并迁移旧进度。
2. **旅行状态机（已实现）：** 五个状态、停留计时、路费、夜航兜底；“用量翻倍”测试继续通过。
3. **选城（已实现）：** 从家算单程距离，八成“当天能到”（0.3–0.8×M），两成“随便走”（≤5×M）；首趟优先当天能到且有资料的城市。
4. **界面：** 刘海待发预告，邮局不在家的样子和地板，地图三种标记和区域视图，护照只列停留，删新国家通知，首个心愿预置。
5. **Hub 第一步：** 配置开关、城市内容拉取、心愿解析，全部可失败。
6. **同城偶遇：** 有真实用户后再做。

### 开发顺序

每一步都能单独构建、测试和提交。

1. **存档保护：** 备份、迁移框架、`care.json`。
2. **多语言基础：** 本地化资源、语言设置、单位格式、核心层去掉显示文字。
3. **城市数据化：** 内容包结构和校验，迁移 107 座城，国家代码迁移，未知城市不崩溃。
4. **随机下一站：** 新抽站算法，删除选站。
5. **导航和界面骨架：** 五项导航、二级导航，额度移出刘海，菜单调整。
6. **第一次打开：** 选蛋、家乡、起名、航海日志信、出发。
7. **信件和回应：** 内容包情节、多语言正文、回应、习惯、兑现、记忆记录。
8. **行囊和收集：** 行囊、纪念品、手绘菜单、掉落。
9. **邮局和周章：** 房间场景、架子、周章、礼盒、档案。
10. **原生额度：** 关联账号、Codex 和 Claude 适配器、额度状态。
11. **首批内容：** 6 座城验证流程，补到 30 座，中英文都完成。
12. **通知和设置：** 早间通知、设置页、存档导出和导入。

### M2 开发顺序

M1 已进入试用，M2 与试用并行开发，试用反馈可以调整顺序。规则见 [design.md](design.md)。每一步都能单独构建、测试和提交。试用者已有存档，新增字段必须能读旧存档，并有迁移测试。

1. **记忆簿：** 收藏里的记忆簿页面，分“你说过的话”“它学会的事”“特别的日子”，补写特别的日子。
2. **歇脚明信片和重逢信：** 当天打开过主窗口且最终用量为零，日结后写明信片并掉一件旧物，按现有 DeliveryTime 在次日送达；离开 3 天以上回来时写重逢信、给重逢礼；信件引用记忆。
3. **周日长信（已实现）：** 周日按 DeliveryTime 送达，只回顾本地周一到周六已结算的最终里程、工具比例和趋势；按兑现、稀有纪念品、新国家、最长一天选一件大事。信箱有全部、旅行信、明信片、长信分类和各自空状态。
4. **本周心愿（已实现）：** 邮局心愿卡，当前语言关键词解析，有本机模型时补选标签；保存解析快照后接通抽站和情节，关联不到时下一封旅行信说明一次。
5. **足迹和途中线索（已实现）：** 旅途页的最常去、最远、最难忘；每天最多一条途中线索，旅途页和刘海展开区静默展示。
6. **用量事件（已实现）：** 最终里程超过此前 14 个活跃日中位数 2 倍、运行中观察到深夜增量、归一化工具首航（船票），都是表现，不带额外奖励。
7. **幼年和少年形态（已实现）：** 四个角色的外形按阶段变化，以及少年的邮局布置。
8. **重游故事（已实现）：** 按累计线索解锁，再次停留时讲述。
9. **补全城市资料（未完成）。** 其余 basic 城市分批补。

`WeeklyMail.swift` 在成功日结、`CareEngine.process` 完成后生成长信，`AppModel.scan` 调用它；不向养成处理器追加奖励或兑现逻辑。候选只取最近已到的周日，正文读取该周一到周六的 `DayRecord`，趋势要求上一周对应六天都有记录。`Content/weekly-mail.json` 提供完整中英文文案、开头和结尾，加载和 `ContentValidator` 校验支持的槽位及双语完整性；正文与 `WeeklyMailSummary` 一起保存进 `Letter`，旧信不随内容包重写。大事同级按日期和内部 ID 排序，最长一天同里程取较早日期。

Journey 版本仍为尚未发布的 6：可选 `weeklyMailEligibleFrom` 记录启用下界，`lastWeeklyMailSunday` 记录最近处理的周日（无活动也记），`Letter.weeklySummary` 保存六天的统计及大事来源。旧存档缺少启用下界时，成功加载后以当前本地日期登记下一个周日并保存，避免补发；跨周恢复只生成最近一周的一封。长信使用独立种类 `weekly`，与明信片和重逢信一起从显示编号扣除，内部 ID 继续递增。长信不请求天气、地点或照片，不推进保底、兑现、习惯或行囊；阅读仍走既有陪伴日路径。`--snapshot` 包含有趋势及无大事的长信，以及全部四个分类和各自空状态。

`CareState.wish` 保留玩家原文，可选 `wishResolution` 保存已校验标签、解析时间、本地周一起点和已说明的信件 ID。`WishEngine` 按本地周一清空，独立于陪伴日和盖章；旧存档只有字符串或没有心愿都能读取，旧字符串在玩家明确保存时才解析。`AppModel.setWish` 限制 40 个字符，关键词后合并本机模型合法标签并保存；相同原文且已有解析快照时不重算。`AppModel.scan` 和 `processLetters` 传入保存的标签，心愿编辑不重抽已有航段。

`Content/wish.json` 提供与 `tags.json` 对齐的中英文关键词及关联不到的说明，加载和 `ContentValidator` 检查标签覆盖、关键词和双语完整性。`WishContent.resolve` 注入可选模型，3 秒超时、异常或不可用时只用关键词，丢弃白名单以外的输出。`LocalWishModel` 仅在应用层使用 FoundationModels，`canImport` 与 macOS 26 可用性双保护，以弱依赖保持 macOS 14 可启动；会话无工具，心愿只作为不可信分类数据。之后抽站、选情节、切换语言和重启均不重新解析。无标签时说明追加到下一封新生成旅行信的双语正文，`Letter.wishExplanationAt` 与解析时间关联；重放中断的双文件写入时恢复去重标记，不重写旧信。Journey 仍为 6、care 仍为 1，新字段都可选。`--snapshot` 包含心愿卡空状态、40 字已写状态和关联不到的旅行信。

`Footprints` 是只读派生结果：从每日旅行信选中的停留城市统计最常去，从 `route` 与家乡坐标计算大圆距离，从 `care.memories` 和 `specialDays` 关联已送达信件统计最难忘。不保存统计、不调用模型；同分按日期、信件 ID 和城市 ID 稳定排序，等距离按路线最近到达顺序。持久化信件 ID 用允许重复键的索引，未知城市显示占位；未知坐标不当作地理位置参与距离，退役城市不排除。细则见 [我的足迹](design.md#我的足迹)。

Journey 仍为未发布的 6，care 仍为 1。可选 `roadCluesEligibleFrom` 是途中线索的启用日期；新旅程从出发日启用，旧档成功加载后登记当前本地日期并保存，核心 `sync` 也在缺失时以本次日期激活，补算不越过下界。`DayRecord.roadClueDecision` 保存内容版本和可选线索（ID、完整双语原文）；未抽中也保存决定，零用量不保存决定。`JourneyState.apply` 只在有用量、处于启用期且没有决定时抽取，独立盐值的 SplitMix64 只读取种子和日期：先以二分之一概率决定是否有，再按 ID 排序选一句。不依赖用量大小、当前航段、时刻或扫描频率，也不占用其他随机序列。补算用已结束日期的最终用量；当天只检查单调成立的“已有用量”，不拿中间值判断全天强度或城市。

`Content/road-clues.json` 至少有 30 条原创双语文字，加载和 `ContentValidator` 校验版本、唯一 ID、数量、非空中英文与纯文字格式。已保存的有线索和无线索决定都不随内容变动；展示直接读取当日本地记录的双语快照，不回查当前内容包。线索没有信件 ID、不进入养成处理、通知、收信或奖励路径，与 `care.trailClues` 无关。`--snapshot` 包含旅途足迹有数据、空状态和刘海线索，支持中英文。

`UsageEvents.swift` 独立保存表现状态，不输入养成引擎。Journey 仍为未发布的 6，新增可选 `usageEvents`；新旅程从出发日启用，旧档在成功加载、补算之前由 `enableUsageEvents` 以当日本地日期激活，从 `days.byClient` 和旧信 `vehicles` 收集归一化工具基线。`Vehicle.normalizeClientID` 与根仓库 `normalizeClientName` / `normalizeTokscaleClientName` 的工具身份一致；`DayDetail.usage` 额外提供不进里程账本的 `observedTokens`（包括缓存读取、推理）与 `usedToolIDs`（有 token、消息或费用的工具）；首航按这些活动 ID 登记，不按模型或显示名字，缓存读取也可先取得船票、等待之后的旅行信。茶不追溯到启用日前，深夜不补发；已有工具基线不补船票，补算中新出现的工具按首次活动日期登记。跨天补算按日期顺序处理，`openDate` 保证幂等。

日结先补齐里程，再把本次读取的最终值写入可选 `DayRecord.finalUsageFuel`，茶只读该最终值及此前最近 14 个最终燃料大于零的已结算活跃日（回溯遇到旧记录缺该字段时不触发，不能跳过改用更早的样本或用单调记账峰值代替最终值），不用当天里程的单调高水位，也不使用固定最低值。14 项中间两项的和就是两倍中位数，严格大于才触发。`pendingTea` 和 `pendingFirstVoyage` 各保留一条待写双语文字，下一封 daily 在日结时领取到可选 `Letter.usageEventNotes`，`CareEngine` 生成正文时加入双语快照；其他种类不领取。首航待写候选的 `pendingFirstVoyageTicket` 按日期、归一化工具 ID 选最早一张，不受同日扫描先后影响；工具基线与船票也稳定排序。没有旅行信时保留，不新增信件 ID 或通知；重放不修改已生成正文。

`NightWorkObserver` 只在 `AppModel.scan` 成功后观察当天 `observedTokens` 的增量，不用里程燃料替代；扫描结果跨午夜才返回时不把旧日结果记成新日。内存基线不持久化，每次启动、恢复或导入存档、系统唤醒后重建，首次只登记，之后正增量才可触发。23:00（含）至 05:00（不含）使用本地日与周一起点，`nightcapWeeks` 去重，不从补算历史生成。`NightcapEvent` 保存观察时间、本地日期和双语文案；显示到这一夜的 05:00，`Sprites` 和 `RoomArt` 在绘制缓冲中加睡帽，不改宠物资料、角色 ID 或外观存档。

`Content/usage-events.json` 每类至少四条原创双语文案，内容加载与 `ContentValidator` 校验版本、全局唯一 ID、数量、中英文完整和槽位；仅首航支持 `{tool}`，触发时保存完整原文，种子使用独立随机盐，不占用养成、掉落或抽站随机序列。船票在 `usageEvents.tickets`，收藏护照页下方显示工具与本地化日期及空状态，不进入 Item、礼盒、架子或养成。`--snapshot` 包含茶和首航旅行信、邮局及刘海睡帽、船票有内容与空状态，支持中英文。

`PetForm.current` 只映射 `Stage.current(companionDays:)`：蛋与雏用 hatchling，5 日起 juvenile，20 日起 teen，旅人及以后仍 teen。形态不持久化、不读取用量。`Content/pets/*.json` 保留原 `sprite` 和蛋，新增 `juvenile` 20×20 身体，少年叠加已有 `accessories`；`hatchlingMotion` / `juvenileMotion` 声明闭区间 `footRows` 与睡帽左上 `nightcapAnchor`（雏沿用原 12×4 帽子，幼年及以后为 10×4）。内容校验覆盖尺寸、行、调色板、非空配饰、脚行与头部锚点，雏和蛋的原 golden 不变。

`Sprites` 按身体原网格加一行上下浮动空间，用声明的脚行走路；身体和配饰一同运动，睡帽作为临时绘图覆盖层。`Sprites` 与 `RoomArt` 的缓存键都包含形态，房间另包含各摆放位图标；所有绘图关闭插值并按整数倍显示。房间中心 x=132、地面 y=108 不变，身体由 32×32 变 40×40，点击范围随之更新。档案、旅途和陪伴窗口使用当前形态，陪伴窗口由原 150×48 扩为 158×56 并保留底边。固定小位置只有刘海收起区（展开时同一肩部）与菜单栏图标保留 16×16 雏身体，不缩放、不改高度；孵化流程也固定使用雏。

`Content/pet-moments.json` 是完整双语卡片文案，`CityCatalog` 加载，`ContentValidator` 检查两个阶段各一张、双语非空和纯文字。`CareState.seenPetStages` 可选，记录已展示或跳过的阶段，不保存当前外形。新档为 `[]`；旧档缺失时在 `SaveStore.load` / 存档导入校验边界，以当前已达到的阶段建立升级基线并保存，不补演出。卡片仅在主窗口邮局房间展示，等待拆信、周礼盒及其他页面结束；待展示由陪伴日和已看字段派生，关闭主窗口、切换页面不丢待展示项。实际展示时先持久化已看，当前卡片留到继续或跳过；不接通知、刘海或浮窗的打断路径。

`CareState.roomPlacements` 为可选位置/物品记录数组，旧档缺失为空。`RoomDecor` 根据 Stage 检查少年解锁和已拥有的纪念品，移出架子或旧位置后才放入；移回架子时先检查容量，失败保留原摆放。`SaveStore` 使用当前 `ItemLibrary` 清理未知位置、未知或未拥有物品、重复位置/物品；架子先占用，同一位置按首条合法记录保留，不对持久化 ID 使用唯一键字典。新增四处以房间逻辑坐标定位：窗台 (46,61)、柜顶 (1,52)、墙上 (174,10)、地上 (64,110)，图标都是 12×12；窗台的托沿在玻璃下方，说明气泡用上方空墙，不覆盖新增点击区。所有字段不进入奖励或养成规则，Journey 仍为 6、care 仍为 1。

`--snapshot` 新增 `pet-forms`（四角色×雏/幼年/少年，原网格 8 倍）、`pet-nightcaps`（四角色×幼年/少年，8 倍）、`home-teen-full` / `home-teen-empty`、`room-arrangement`、`moment-juvenile` / `moment-teen`、各新形态的档案、陪伴窗口和刘海；沿用 `--language zh-Hans|en --appearance dark|light` 生成对应主题和语言。

M3、M4 和同城偶遇不要提前做，但数据结构要给它们留位置。M2 之后做在线内容包；正式签名、公证和应用自动更新等 Developer ID 和 Sparkle 决定后再做。

### M1 验收

- 同一份用量翻倍后，习惯、形态、陪伴日、周章、信的数量、掉落稀有度和保底、兑现时机完全相同；城市和当地内容可以不同（测试）。
- 用旧版 `journey.json` 启动不丢数据；损坏的存档不被覆盖（测试）。
- 删掉一座城后，含该城的存档仍能启动并显示占位（测试）。
- 加一座城只需改内容文件，不改代码（测试 + 手动）。
- 简体中文和英文下，所有界面没有截断或写死的另一种语言（快照检查）。
- 切换语言后旧信也切换（测试）。
- 第 3 封信前一定出现一次回应兑现（模拟测试）。
- 没有用量、断网、tokscale 失败时都能打开并给出提示（手动）。
- `swift test` 通过，`--snapshot` 能生成所有界面的中英文截图。

## 选型结论

**独立的 Swift 原生应用（SwiftUI + AppKit），用 tokscale 命令行工具采集用量。** 放在 `voyage/` 目录，不修改 Token Monitor 现有代码，也不依赖它运行。这取代了早先"Electron 插件"的提议。

| 方案 | 原生 | 对现有代码的入侵 | 用量覆盖 | 结论 |
|---|---|---|---|---|
| Swift 应用 + tokscale | 是 | 无 | 约 60 种工具，与 Token Monitor 同一引擎 | 选用 |
| Token Monitor 插件 | 否，运行在 Electron 渲染进程 | 低，但插件 API 仍是实验性的，够不到 WidgetKit | 全部 | 不满足原生 |
| 改 Electron 主程序 | 否 | 高，上游更新频繁，合并成本大 | 全部 | 否决 |
| 读 Token Monitor 的 Hub、小部件快照或凭据文件 | 可以 | 用户必须安装并运行另一个产品 | 全部 | 否决，这是独立应用 |
| Swift 自己解析各工具日志 | 是 | 无 | 只能覆盖少数工具，重复造轮子 | 否决 |
| 基于 agentpet | 是 | 需要安装 agent 钩子 | 约 11 种 | 否决 |

## 关键实测

在 M2 Pro、macOS 27、约 228 个活跃日的数据上：

- 全量 `tokscale graph`：约 29 秒，约 70 CPU 秒。
- 单日 `tokscale graph --offline --since D --until D`：约 1.6 秒，约 4 CPU 秒。
- 二进制约 20 MB，npm 包为 `@tokscale/cli-darwin-arm64@4.21.0`，MIT 协议。

由此得出的决定：

- 平时只扫当天。看板显示时才读全部每日数据和当天每小时数据，缓存 5 分钟；所有范围都从这份数据切出来。
- 每小时读取只在看板显示时做，30 天的结果缓存 1 小时。
- 只在工具目录发生变化时才扫描，最短间隔 60 秒，兜底 5 分钟一次。
- 用量采集始终带 `--offline`，不发网络请求。
- 额度是例外，用户关联后才会读本机凭据并请求服务商，见[用户关联账号和额度](#用户关联账号和额度规划)。
- 扫描串行执行，进程设为低优先级。

应用本身待机时约占 0.4% 单核、70 MB 内存（不含 tokscale 扫描）。

## 结构

```text
voyage/
├── Package.swift            Swift 包，无第三方依赖
├── Content/                 城市、情节、物品等内容数据（M1 起）
├── Sources/VoyageCore/      纯逻辑：引擎、内容解析、信件、解析，全部可测
├── Sources/TokenVoyage/     应用：AppKit 窗口、SwiftUI 界面、采集、网络
├── Tests/VoyageCoreTests/   核心逻辑测试
├── Tests/TokenVoyageTests/  本地化和信件文字测试
├── scripts/                 打包脚本、地图生成脚本
└── docs/
```

只依赖系统框架；增加依赖（比如自动更新）要先讨论。构建时才下载 tokscale 和像素字体，放到被忽略的 `.vendor/`，不提交二进制文件，也不接入根目录的 `npm` 脚本和 CI。

## 数据流

```text
工具日志 → tokscale graph → UsageSource（解析全部 token 与工具占比）
        → JourneyState.sync（确定性推进）→ journey.json
        → AppModel → 刘海 / 浮窗 / 主窗口
新信 → Enricher（天气、Wikipedia、像素照片）→ journey.json
tokscale hourly → 待日结日期的未计入差额 → JourneyState（小时补算）
tokscale graph / hourly → UsageDashboard（趋势、活跃、明细）→ 看板
```

## 引擎不变量

- **里程记账：** 航段进度按全部 token 的整数增量保存，去程按 1,000,000 token/km、回程按 100,000 token/km 推进；停留和待发不直接增加里程，路费溢出按去程系数计入累计公里；累计公里单独存为 `totalKm`，不再由累计 token 换算。日中位数只读已有 `tokens` 的近 14 个活跃日，按去程系数换成公里；选城的 M 最小为 300 km。
- **确定性：** 相同存档、内容包及输入序列得到相同旅程。下一站读取心愿和重游候选，随机抽签由种子加已完成趟数决定，首趟之后只在到家时抽取下一站并保存。
- **选城：** 排除家、最近 3 个停留城市和下线城市；候选为空时只放宽最近停留排除。按从家的单程距离，80% 抽 0.3–0.8×M（含端点），20% 抽 ≤5×M；后者也包含前者的城市。某档为空就用另一档，两档都空时取最近的合格城市，同距离按 ID 排序。首趟按 M=300 km 优先抽当天能到且有资料的城市，否则取最近的有资料城市，再退回最近城市。距离阈值、档权重及城市乘数都在 `DestinationPicker.Configuration`。
- **只增不减：** 当天统计值下降时不回退里程。
- **精确增量：** 每次只推进"新值 − 已记录值"。
- **跨天结算：** 先用前一天的最终值补差，再结算，已结算的日子不再改动。应用关闭多日后，逐日按小时末尾补算未计入的差额，小时数据不可用时退回当天 23:59。
- **航段快照：** 抽到下一站时把距离和两端坐标写进存档，内容包修改坐标或删除城市都不影响已保存的路线和进度。
- **信件 enrich 失败不影响旅程：** 信件先由模板生成，网络内容是可选的补充。

## 一趟旅行

规则见 [design.md 的一趟旅行](design.md#一趟旅行)。这一节只写实现上要守住的东西。

### 状态

`JourneyState` v8 保存以下状态；旧存档通过 v7 → v8 迁移补齐（`totalKm` 已在 v7 实现）：

| 字段 | 含义 |
|---|---|
| `homeCityId`、`homeCoordinate` | 家，来自第一次打开的选择；旧存档取 `route.first` |
| `phase` | `home`、`pending`、`outbound`、`staying`、`returning` |
| `phaseSince` | 进入当前状态的时间；待发的 30 分钟和停留的 6 小时由它算 |
| `totalKm` | 累计里程，公里（小数）。两段系数不同，token 数不能再直接换成公里，所以单独记 |
| `travelFund` | 路费，token 整数 |
| `tripCount` | 已完成的趟数，作为抽站随机数的输入，取代已到站数 |

航段快照（距离和两端坐标）继续保存；回程的航段是目的地到家，系数不同。进度仍用 token 整数记账，去程每公里 1,000,000，回程每公里 100,000。

`route` 只记停留过的城市（不含每次回家），家只看 `homeCityId`；足迹、护照、`CareEngine` 和 `DestinationPicker` 的“最近停留”都按这个含义读。`DayRecord.tokens` 已在 v7 保存当天全部 token，日中位数 M 和信里的“比平时多少”都读它；原来的 `fuel` 和 `byClient` 保留旧记录、工具比例和既有用量事件的未缓存口径。新信同时保存 `tokens`，旧日记录和旧信的公里显示沿用旧系数。

### 旧存档迁移

里程口径和状态机各升一次 Journey 版本，迁移只用存档里已有的数据：

- v6 → v7：已保存航段的 `legCost` 和 `legFuel` 同乘 100，保留进度比例及坐标快照，不重新抽站。
- 旧的 `totalFuel` 除以 10,000 存成 `totalKm`，界面上的累计公里不跳。
- v7 → v8：家取 `route.first`；正在走的这一段当作去程，航段进度和坐标不变，`route` 去掉开头的家，`tripCount` 取已停留的城市数，路费为零，`phaseSince` 取 `openDate` 的 UTC 零点。家乡坐标从内容包读取，连续赶路的旧档在第一段之后没有保存家的坐标；内容包里找不到这座城时才退回已有端点：目标是家时取 `legTo`，其余取 `legFrom`。
- 旧日记录没有 `tokens`。升级后的首次成功扫描覆盖最近约 14 个已知活跃日，补回能读取的记录；读不到的日子不参与中位数。回填只补观察值，不重放里程或重写旧信；尚未结算的旧当天也先建立全部 token 基线，此后的增量才推进。

### 用量怎么分配

每次扫描得到一个增量，按当前状态消耗，剩余部分带进下一个状态：

1. `home`：进入 `pending`，增量先记着。
2. `pending`：累加；到 30 分钟或玩家点立刻出发时转 `outbound`，累加的量算进去程。
3. `outbound`：推进去程；走完转 `staying`，多出来的进路费。
4. `staying`：全部进路费，超过上限的部分只加到累计里程。
5. `returning`：先扣路费再用增量；走完转 `home`，抽下一趟目的地，剩余增量触发新的 `pending`。

状态切换由时间触发的两处（待发结束、停留结束）在每次扫描和定时器里检查，以写进存档的 `phaseSince` 为准。路费上限取此前已结束的最近 14 个活跃日的 `tokens` 中位数，沿用偶数样本取中间较大值的口径；无样本时为零，日内上限不随扫描变化。

引擎不读系统时钟：`sync` 接收 `now: Date` 参数，实时扫描传扫描时刻，测试和快照传固定时刻。“立刻出发”是 `JourneyState` 上单独的方法，同样传入 `now`，由 AppModel 调用。第一次打开时选完行囊直接进入 `outbound`，不经过 `pending`。

### 时间和补算

连续赶路的旧引擎只看每日用量，所以逐日补算和实时扫描结果相同。新状态机依赖一天之内的时刻，补算要有小时粒度：

- **实时：** 用扫描时刻。
- **补算已结束的日子：** 用 `tokscale hourly` 的每小时用量，按小时末尾的时刻依次送进状态机；23 时桶使用当日 23:59:59，保持自然日归属。
- **不重复计入：** `DayRecord` 记 `lastObservedAt`（最后一次实时计入的时刻）。结算时只把“当天总量减去已计入”的差额送进状态机，按 `lastObservedAt` 之后各小时的用量比例分配；那之后的小时都没有用量时，差额记在 23:59。
- **退回：** `tokscale hourly` 只有最近 30 天，读一次 30 天要约一分钟 CPU，所以只读需要补算的那几天。超过 30 天或读取失败时，差额全部记在当天 23:59，不重试到阻塞扫描。
- **取舍：** 同一天实时算和事后补算，状态切换时刻最多差一小时，到站时间可能不同。已写进存档的状态和航段不重算，所以不会改历史；测试固定输入时刻来验证可复现。
- **夜航兜底：** 停留结束后的下一个自然日结算时，当天全部 token 为零就直接到家。

### 不变的东西

- 用量无关的结果（习惯、形态、陪伴日、周章、信的数量、掉落稀有度和保底、兑现时机）不读 `phase`、路费或趟数以外的旅行状态；“用量翻倍”测试照旧。
- 一天最多一封旅行信，仍只为当天有观测用量的日子生成。跨日待发靠已计入的用量在零用量日到站时，不额外发信，停留仍计入足迹和重游资格。当天有到站就写这一站；一天停了两站，同一封信里两站都写，各用一段到站情节，掉落、稀有度和保底仍按一封信算。没有到站写途中信。停留跨过午夜时，只有到站那天的信写这座城，第二天算途中信。
- 抽站只在到家时发生一次并保存；心愿和重游候选在那一刻读取。

### 品牌合作的预留

`items/` 和 `stories/` 的条目加可选的 `sponsor`（合作方 ID 和双语标注文字），内置内容不填。有 `sponsor` 的条目只来自服务端内容，受 Hub 配置开关和本机设置开关共同控制；掉落逻辑把它当作一个普通掉落位，每个本地周最多一次，不读用量。

## 养成引擎（M1 起）

养成是 `VoyageCore` 里独立于 `JourneyState` 的纯逻辑。养成消费旅程已结算的信，不反向影响里程；途中线索独立保存在日记录，不进入养成处理。

- **用量无关：** 习惯、形态、掉落稀有度、保底、陪伴日和信件数量不随用量翻倍改变；城市、故事和当地收藏可以不同。故事选择不直接读取 token 数。
- **确定性：** 掉落和情节由 `seed`、信件序号、到达的城市、此前停留、累计线索、已讲重游、习惯、工具和保底计数决定。日结后的信按序处理，补算时先记账前一封的效果；同一存档、内容包和种子重算一致。实时天气不参与选择，雨中故事按城市资料里的雨季触发。
- **幂等：** 按信件序号和日期记账，重复处理不会重复发放。
- **途中线索：** 只由种子和日期抽取并保存双语快照；不占信件编号，不推进奖励、保底、兑现、习惯、陪伴日或周章，也不修改旅行线索 `trailClues`。
- **兑现时机：** 只由种子、信件序号和回应决定，不看到了哪座城。到期后才选能兑现的情节。
- **下一站：** 由引擎按从家的距离八二抽档，档内按是否去过、新国家、心愿标签、已解锁未讲的重游城市、资料和知名度加权，玩家不选。抽站由种子和已完成趟数决定；M 读到家抽签当天之前的最近 14 个活跃日，按去程系数换算，最小或无数据时为 300 km，避免结果随当天扫描时机变化。
- **心愿解析：** 只在写入时按当前语言的内容关键词匹配，有本机模型时再补选已有标签；模型不可用、超时或失败时保留关键词结果。原文和解析快照只存本机，抽站和选情节只读快照。每周一本地时间清空；关联不到就随机，下一封旅行信说明一次。
- **偏离事件：** 茶只比较日结的最终用量和此前最近 14 个活跃日的真实中位数，样本不足不触发；深夜事件用运行中扫描观察到的增量和本地时间，应用未运行、唤醒后的首次扫描不补发。首航按归一化工具 ID 去重，独立于养成。

## 内容包（M1 起）

城市、情节、物品和文案都是数据。代码只认结构，加内容不改代码。

### 目录

```text
voyage/Content/
├── manifest.json        版本和兼容信息
├── tags.json            统一标签表
├── wish.json            双语心愿关键词和关联不到的说明
├── road-clues.json      原创途中线索，中英文纯文字
├── usage-events.json    茶、睡帽和首航的原创双语文案
├── countries.json       国家和地区名称，按 ISO 代码
├── published-ids.txt    发布过的城市 ID
├── world/cities.tsv      全球城市基础数据，由 scripts/generate-world-cities.swift 生成
├── cities/              有资料的城市，每城一个文件，按 id 或 wikidata 覆盖基础数据
├── stories/             情节，按城市或通用分类
├── items/               行囊、纪念品、菜单（kind、rarity、habit、icon、各语言名称和说明）
├── themes/              界面主题，加一套只加一个文件
├── friends.json         邮友
└── boxes.json           礼盒清单
```

随应用打包时放进资源；在线内容包结构相同。

### 城市格式

基础数据只有 ID、坐标、国家、大洲、知名度档位和中英文名，ID 是小写的 Wikidata 编号。启动时只解析，完整校验在测试里跑。存档里的基础 ID 在有了单独文件后仍能通过 `wikidata` 找到。下面是单独文件的格式：

```json
{
  "id": "quanzhou",
  "status": "active",
  "lat": 24.87,
  "lon": 118.68,
  "countryCode": "CN",
  "continent": "asia",
  "tags": ["coast", "food", "heritage"],
  "level": "full",
  "names": { "zh-Hans": "泉州", "en": "Quanzhou" },
  "wikipedia": { "zh-Hans": "泉州市", "en": "Quanzhou" },
  "facts": [
    {
      "id": "xunpu",
      "type": "place",
      "names": { "zh-Hans": "蟳埔村", "en": "Xunpu Village" },
      "sources": ["https://example.org/verified-source"]
    }
  ]
}
```

`status` 只有 `active` 和 `retired`。`level` 是 `basic`、`facts` 或 `full`。

### 情节格式

```json
{
  "id": "quanzhou.breakfast.1",
  "version": 1,
  "cityId": "quanzhou",
  "factIds": ["mianxianhu"],
  "kind": "arrival",
  "tags": [],
  "requires": { "habit": "talkative", "item": null, "season": null, "tool": null, "rainySeason": null },
  "fulfills": ["generic.arrival.breakfast.ask"],
  "fulfillsHabit": null,
  "lead": null,
  "text": {
    "zh-Hans": "早餐摊的阿姨教我把油条留一半脆的。",
    "en": "The breakfast stall owner taught me to keep half the youtiao crisp."
  },
  "replies": [
    { "id": "quanzhou.breakfast.1.draw", "habit": "observant", "text": { "zh-Hans": "把你看见的画下来", "en": "Draw what you saw" } }
  ],
  "rewards": { "itemIds": ["quanzhou.youtiao-note"], "menuIds": ["quanzhou.mianxianhu"] }
}
```

`kind` 是 `arrival`、`transit`、`fulfill`、`revisit`、`postcard` 或 `reunion`。明信片和重逢信这两类必须是无条件、无城市的通用内容，不设回应、兑现或指定奖励；其 `text` 可直接独立成文，另用双语 `memoryLead`（含 `{memory}`，可含 `{pet}`）作为有记忆时才加入的引句。它们的正文只支持 `{pet}`，不使用城市事实。旧物和重逢礼在 `items/` 中用 `source: "postcard"` / `"reunion"` 分池，前者每种稀有度都有候选，后者固定普通。其余旅行情节的正文可以带 `{pet}`、`{city}`、`{target}`、`{reply}` 槽位，生成信时填好；槽位不能拼接语法，比如英文复数要写成完整句子。

回应 ID 在整个内容包中全局唯一，`fulfills` 引用这一条具体回应。专属兑现延续原信里的事物，`lead` 用 `{reply}` 引用玩家的话；没有专属情节时才用 `fulfillsHabit` 习惯模板，模板须自成一体。`kind` 为 `fulfill` 且 `cityId` 为 `null` 时，正文和引句不能用 `{city}`，因为兑现当天可能仍在途中。

### 校验

`swift test` 里的内容校验必须覆盖：

- ID 唯一，引用的城市、事实、物品和标签都存在。
- 事实条目至少有一个来源，`file` 或占位网址不能通过发布校验。
- `zh-Hans` 和 `en` 都完整，槽位在各语言里一致；包含明信片、重逢信的正文和记忆引句，且各稀有度旧物及重逢礼都有候选。
- 坐标在有效范围，国家代码有效。
- 已发布过的城市 ID 不能消失，只能改为 `retired`（对比 `Content/published-ids.txt`）。

### 在线内容包（公开发布前）

```json
{
  "formatVersion": 1,
  "packVersion": 12,
  "minAppVersion": "1.0.0",
  "sha256": "…",
  "signature": "…"
}
```

- 用 Ed25519 验证签名，公钥打包在应用里；验证失败就继续用当前版本。
- 只接受 `packVersion` 更大的包，防止回退。
- 内容包只有数据，不含可执行内容；文字一律按纯文本显示。
- 取用顺序：最新且验证通过的下载包 → 应用内置包。
- 请求不带用量和身份信息。

### 确定性

抽站结果和信在生成时就保存，以后不重算，所以内容包更新不改变历史。测试里固定内容包版本来验证可复现。

## 多语言实现（M1 起）

- **界面：** 用 String Catalog（`Localizable.xcstrings`），key 是语义化的（如 `nav.journey`）。所有文字都经过 `L10n`，不用 `LocalizedStringKey` 隐式查找，这样菜单和错误提示走同一条路径。`build-app.sh` 把资源 bundle 复制到 `Contents/Resources/`。
- **语言设置：** `system`、`zh-Hans`、`en`，存在 UserDefaults 的 `language` 键。切换时界面和信件立刻刷新，不用重启。
- **核心层：** `VoyageCore` 不返回显示文字，只返回语义和数字。显示层负责翻译。
- **格式：** `Format.tokens` 按语言输出万亿或 K、M、B；日期用系统格式器。
- **快照：** `--snapshot` 支持 `--language en`，每种语言生成一套截图。

## 信件生成

```text
结算一天 → 选城市 → 选情节 → 决定掉落 → 按所有语言生成正文 → 保存
                                              ↓
                               Enricher 在线补天气和地点介绍（可失败）
```

信保存：

```json
{
  "id": 37,
  "kind": "daily",
  "date": "2026-11-05",
  "cityId": "quanzhou",
  "storyId": "quanzhou.breakfast.1",
  "storyVersion": 1,
  "texts": { "zh-Hans": "…", "en": "…" },
  "replyOptions": [{ "id": "draw", "habit": "observant", "text": { "zh-Hans": "…", "en": "…" } }],
  "selectedReplyId": null,
  "rewards": { "itemIds": [], "menuIds": [] },
  "weatherCode": 61,
  "temperatureC": 14,
  "place": { "en": { "title": "…", "summary": "…", "url": "…" } }
}
```

- **快照：** 正文和选项全部写进信，内容包修订不影响旧信。
- **槽位：** 宠物名填入时不翻译。
- **地点介绍：** 按当前语言请求对应语言的 Wikipedia，不跨语言回退；切换语言后打开这封信时再请求，失败就不显示。
- **选择情节的顺序：** 到期的兑现 → 已解锁的重游 → 行囊触发 → 符合工具和季节 → 符合习惯 → 符合心愿标签 → 该城通用 → 无资料模板。同级用种子随机，并避开最近 10 封用过的。
- **重游判断和记账：** `RevisitStories` 按城市内的故事 ID 稳定排序，第 N 个需要 `care.trailClues[city] >= 3×N`，线索不扣减。只在已结算的 daily 首次生成正文时，从当前选中的故事城市取候选，并要求更早日期的 daily 已有该城停留（非途中、非路过）。到期兑现优先；讲述后用可选 `CareState.toldRevisitStoryIds` 去重。旧档缺失视为空，已有线索立即解锁，不补信。跨天信按 ID 处理，已讲的故事不再候选。
- **重游快照：** Journey 仍为 6，care 仍为 1。可选 `Letter.isRevisit` 与正文、回应及 `storyId` 同时保存，界面不回查内容包推断标记。重放 journey 已保存而 care 未保存的中断状态时，先恢复已讲记账，再按原规则应用奖励；旧信不重写。普通掉落、习惯加成、兑现时机和陪伴日不变。
- **重游抽站：** 应用层用当前 care 与内容包派生 `revisitCities`，与 `wishTags` 一样传入 `JourneyState.sync` 和 `DestinationPicker`，不保存候选集；档内城市权重额外乘 3，可以和心愿乘数叠加。只影响下一次新抽签，不重抽已保存航段；讲过后从候选集中移除，没有故事的城市不进入候选。
- **重游内容：** 每座 full 城市至少一篇 `kind: "revisit"`，必须带 `cityId`、本城已有的 `factIds`、双语 lead/text 和两种习惯各一个回应；无额外条件、兑现或指定奖励。`ContentValidator` 检查基线和格式，事实引用沿用本城校验。收藏页派生不足、解锁、讲过状态，零线索隐藏，无故事只显示累计数量。`--snapshot` 包含重游信和同页三种线索状态，支持中英文及明暗主题。
- **兑现选择：** 满足 `requires` 且 `fulfills` 包含当前回应的情节，不受 `kind` 限制；优先当前城市，其次 `cityId: null` 的专属情节，再用习惯模板。每封信最多兑现一个承诺；积压承诺排到队首后，才开始计算三封信的兑现窗口。

## 存储和迁移

`~/Library/Application Support/TokenVoyage/`：

- `journey.json`：全部旅程状态，原子写入。
- `care.json`：宠物名和孵化信息、陪伴日、习惯、身份、行囊、收藏、周章、心愿、记忆簿（M1 起）。与旅程分开，改养成不必动已验证的旅程状态。
- `backups/`：迁移前和解码失败时保留的存档。
- `content/`：下载并验证过的内容包（公开发布前）。
- `photos/`：像素化后的地点照片。

测试和调试可用环境变量 `TOKEN_VOYAGE_DATA_DIR` 改写路径。

游戏里累积的历史就是产品的价值，存档必须能跨版本读取。当前有两个需要在 M1 前修掉的问题：

- `AppModel.init` 在 `journey.json` 解码失败时会新建旅程，`start()` 随后立刻覆盖旧文件。
- `JourneyState` 使用合成的 `Codable`，新增非可选字段就会让旧存档解码失败，即使字段有默认值也一样。

M1 先做：

- **解码失败：** 把旧文件移到 `backups/`，显示存档页面，让用户导入备份或重新开始，不静默覆盖。
- **迁移：** 读取时先看 `version`，逐版本迁移；迁移前备份，写入用原子替换。
- **新版本存档：** 遇到比当前应用更新的版本时拒绝写入，提示更新。
- **第一个迁移：** `country` 中文名转 `countryCode`，并写入航段快照。中文名到代码的映射永久留在迁移代码里。第二个迁移去掉 `nextChoiceId`，不重新抽站。
- **M0 存档：** 有 `journey.json` 但没有 `care.json` 时自动生成：沿用现有宠物和默认名，不重新孵化，不补发陪伴日和旧信掉落。
- **导出和导入：** 设置里可以把存档打包导出，导入前校验。

**第一次打开：** `journey.json` 和 `care.json` 都不存在时才走流程。走完才一次写入，中途退出不留文件。

`care.json` 结构：

```json
{
  "version": 1,
  "petName": "阿鸽",
  "species": "pigeon",
  "hatchedAt": "2026-11-06",
  "companionDays": ["2026-11-06"],
  "habits": { "talkative": 20, "observant": 10 },
  "identity": null,
  "bag": { "owned": ["sketchbook", "note-slip", "raincoat"], "todayItem": "sketchbook" },
  "souvenirs": [{ "id": "jingdezhen.note", "letterId": 3, "shelved": true }],
  "menus": [{ "id": "jingdezhen.cold-noodles", "letterId": 3 }],
  "trailClues": { "jingdezhen": 2 },
  "weekly": { "weekStart": "2026-11-02", "stamps": ["2026-11-02"], "boxes": [] },
  "wish": null,
  "pendingPromises": [{ "replyId": "ask-next-time", "letterId": 2, "attempts": 0 }],
  "memories": [{ "kind": "reply", "date": "2026-11-05", "letterId": 2, "replyId": "ask-next-time" }],
  "pity": 3,
  "processedLetterIds": [1, 2, 3]
}
```

记忆存引用而不是译文，显示时按当前语言取；玩家写的字保存原文。

M2 第 2 步的 `journey.json` 升到版本 6：新增可选的 `lastOpenedDate`，每日记录新增 `mainWindowOpened`（缺失时为 false），只记录本机主窗口的实际打开。旧版本迁移不填历史打开记录。`JourneyState.sync` 在成功扫描后按日期顺序日结：有用量写旅行信，零用量且打开过写明信片，沿用 DeliveryTime 的次日送达时间；结算游标 `openDate` 保证每日只生成一次，扫描失败不推进。信件新增 `postcard` / `reunion` 类型，可选 `memoryReference`（记忆来源）和默认空的 `rewardItems`（物品快照）。`care.json` 继续版本 1，沿用 `processedLetterIds`、收藏、陪伴日和保底记账，不新增必填字段。先保存 journey，再保存 care；启动时按已存信件快照补齐中断的 care 写入，不重新抽选。陪伴日只由阅读已送达信件记录，写信和主窗口打开均不记账。显示编号从原 ID 中扣除前面的明信片与重逢信，二者以信件类型标题显示；不修改持久化 ID 或任何抽选输入。`memoryLead` 填入记忆时去掉引用文本末尾的中英文句点，由引句提供标点，不改来源快照。

## 用户关联账号和额度（规划）

Voyage 是独立应用，运行时不依赖 Token Monitor。tokscale 继续负责用量；额度由 Swift 原生适配器读取，可以参考 Token Monitor 的实现思路，但不共享进程、文件和服务。

### 数据来源

| 数据 | 来源 | 说明 |
|---|---|---|
| 用量、里程、看板 | tokscale 本机日志 | 不需要关联，不联网 |
| 额度 | 原生适配器；没有适配器的工具用 `tokscale usage` | 用户关联后才请求服务商 |

### 关联方式

每个工具声明自己支持哪些方式，统一由一个“关联账号”界面展示。

| 方式 | 流程 | 适用 |
|---|---|---|
| 使用本机登录 | 用户点“关联”后，才读取工具已有的登录信息；读取钥匙串时由系统弹窗确认 | Claude、Codex 等 CLI |
| 粘贴密钥 | 粘贴后先请求一次校验，成功才保存（未实现）| API key、网页会话 |
| 网页授权 | 打开官方授权页，用设备码完成登录（未实现）| GitHub Copilot 等 |

规则：

- **默认不读取：** 第一次打开不碰任何其他应用的凭据，用户逐个工具关联。
- **只读：** 第一版不刷新其他工具的令牌，以免刷新令牌轮换后把原工具登出。令牌过期时提示用户回到该工具登录。
- **存储：** 自己保存的密钥放进钥匙串，仅本机可用；其他工具的凭据用完不落盘。
- **边界：** 凭据只在额度运行层使用，界面只拿到显示数据，日志和 `journey.json` 都不含凭据。
- **断开：** 每个工具可随时断开，同时删除它的密钥和额度缓存。

### 适配器接口

```swift
public protocol QuotaProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var linkMethods: [QuotaLinkMethod] { get }
    func detectLocalLogin() async -> QuotaCredential?
    func validate(_ credential: QuotaCredential, transport: any QuotaTransport) async throws
    func fetch(_ credential: QuotaCredential, transport: any QuotaTransport) async throws -> QuotaReading
}

public enum QuotaStatus: Sendable {
    case notLinked, ok, stale(lastGoodAt: Date), expired, rateLimited(until: Date?), unavailable(String)
}
```

响应解析放在 `VoyageCore`，用脱敏样本测试；钥匙串和网络放在应用层。`QuotaTransport` 可注入，测试不发真实请求。

### 额度运行层

- **互不影响：** 每个工具一条独立队列，有超时；同一工具只保留最新一次请求。
- **失败处理：** 按 `Retry-After` 和指数退避重试；保留上次成功的数值，并标明读取时间和状态。
- **触发：** 启动、唤醒、固定间隔和手动刷新。用量变化永不触发。
- **未知不是零：** 没读到的工具显示状态和下一步操作，不显示 0%。

### 适配顺序

额度只在“数据 → 额度”面板显示，刘海、浮窗和小部件不显示。API 直连的工具没有额度窗口，状态是“按量计费”，不是 100%。

按实际使用排序：Codex、Claude、Kimi、Copilot，其余先走 `tokscale usage`。这些接口大多不是公开文档接口，随时可能变化：请求失败不影响其他功能，并且要能单独关闭。

## Voyage Hub：内容、心愿和同城偶遇（规划）

Voyage Hub 不放进仓库现有的 `worker/`，那是 Token Monitor 的 Worker，有自己的隔离规则。

Voyage Hub 是 Voyage 自己的服务，和 Token Monitor 的 Hub 没有关系。它做三件事：按城市提供生成好的内容，解析心愿，给同城停留的宠物配对。旅程进度始终在本机按用量计算，Hub 连不上时单人玩法完全不受影响。

城市内容和心愿解析默认开，偶遇默认关、用户明确开启后才登记停留；三项都能在设置里单独关闭。

### 部署

- **入口：** 放在 Cloudflare 后面，在那里做配置开关、健康检查和限流；任一项功能都能手动关掉，客户端读到关闭就走本机回退。
- **存储：** 前期直接用数据库保存城市内容和停留记录，不把只存在缓存里的数据当作唯一来源，重启不能丢。
- **规模：** 前期小规格服务器即可，按实际用量再扩。
- **模型：** 用低成本模型，密钥只在服务端。具体模型未定。

### 生成

- **按城市，不按用户：** 城市玩法、问题和纪念品由离线任务批量生成后入库，所有用户共用；同类已有就复用，没有才新增。
- **不在请求路径上调模型：** 出发和到站的请求只读库。心愿解析是唯一在线调用模型的接口，结果按心愿文字缓存。
- **进库前校验：** 生成结果按内容包的同一套结构和 `ContentValidator` 规则校验，双语完整才可用；模型输出一律当不可信数据，文字按纯文本显示。

### 原则

- **最小数据：** 内容请求只带城市和语言；心愿请求只带心愿文字；停留登记只带城市、日期和角色外观。
- **绝不上传：** token 数、费用、工具、模型、项目、会话、邮箱、宠物名和本机路径。
- **自由文本只有心愿：** 只用于解析标签，服务端不留存原文；偶遇不传任何自由文本，不需要内容审核。
- **设备身份：** 设备生成 Ed25519 密钥放进钥匙串，请求用它签名，用于限流和配对；没有账号。
- **防作弊：** 开启偶遇后存档绑定这个设备密钥并定期同步。服务端按日期校验（一天最多一次停留）、拒绝不存在的内容 ID。这只能挡住随意改存档，挡不住改客户端；用量不上传，所以不校验里程。
- **离线优先：** 任何请求失败时旅行和信照常进行，用内置内容和本机关键词。Hub 只增加内容，不影响里程、习惯、形态和掉落概率。

### 接口草案

所有路径带版本，字段只增不改，写入都带客户端生成的 ID 以便安全重试。

| 接口 | 什么时候调 | 作用 |
|---|---|---|
| `GET /v1/config` | 启动和每天一次 | 读各功能开关；读不到用本机默认。选城参数是否也从这里下发见 design.md 的待确认 |
| `GET /v1/cities/{cityId}/content?lang=` | 出发时一次 | 取这一趟要用的玩法、问题和纪念品；拉不到用内置内容 |
| `POST /v1/wishes/resolve` | 写心愿时 | 返回已有标签；3 秒超时后用本机关键词 |
| `POST /v1/stays` | 到站时一次，偶遇开启才调 | 登记在这座城停留；同城已有等待中的宠物就配成一对并返回对方外观 |
| `GET /v1/stays/{stayId}` | 停留期间和到家时 | 查这次停留后来有没有被配上 |
| `PUT /v1/sync` | 定期 | 同步收藏的内容 ID，用于校验和换设备恢复 |
| `DELETE /v1/me` | 用户删除数据 | 删除这个设备身份的全部数据 |

```json
{
  "stayId": "018f…",
  "cityId": "quanzhou",
  "day": "2026-11-06",
  "appearance": { "species": "pigeon", "stage": "traveler" }
}
```

配对规则：同一座城里两只都在停留就配，先到先配，一只宠物一次停留最多配一次；不攒批次、不优先好友。客户端收到配对后生成一张合影明信片，同一座城已有合影就不再生成。停留记录的保留期限要在上线前确定。

## 窗口实现

- **应用类型：** `LSUIElement` 菜单栏应用，不占 Dock。
- **刘海：** 非激活 `NSPanel`，窗口只覆盖可见区域，所以不需要全局鼠标监听，也不用点击穿透。尺寸取自 `safeAreaInsets` 和 `auxiliaryTopLeftArea`；无刘海屏幕显示为顶部小条。
- **浮窗：** 非激活 `NSPanel`，用 `performDrag` 拖动，位置自动保存。
- **像素渲染：** 地图先生成 `CGImage`，再以 `.interpolation(.none)` 按整数倍显示。
- **精灵动画：** 用 AppKit 定时重绘，不用 SwiftUI `TimelineView`；后者实测占约 12% 单核。

## 小部件的路径（M4）

SwiftPM 无法构建 app extension。届时加一个最小 Xcode 工程，引用 `VoyageCore`，通过 App Group 共享 `journey.json` 的摘要和照片。本机已有 Apple Development 签名身份和 Xcode 27.2。

## 已知限制

- **tokscale 版本：** 用的是上游 4.21.0，不是 Token Monitor 固定的 fork 构建，所以 fork 专有的 CatPaw、Qoder CN 不计入。
- **需要登录同步的工具：** Cursor、Antigravity 等依赖 Token Monitor 或 `tokscale` 的同步命令刷新缓存，第一版不主动同步。
- **与 Token Monitor 同时运行：** 两者的刘海窗口位置相同，会互相遮挡。可在菜单栏关闭其中一个。
- **签名：** 目前是 ad-hoc 签名，只适合本地测试。公开发布要用 Developer ID 签名和公证，内置的 tokscale 也要一起签名。
- **架构：** 目前只打包 arm64，发布前决定是否支持 Intel。
- **外接显示器：** 刘海只显示在带刘海的屏幕上，主要看外接屏时靠浮窗。

## 公开发布的技术准备

本地测试阶段不做，发布清单见[产品设计](design.md#发布计划)。

- **签名：** Hardened Runtime、公证，内置二进制和 dylib 逐个签名。
- **更新：** 应用更新优先用社区通用的 Sparkle，这是新依赖，要先讨论；内容包走自己的签名更新。
- **隐私：** 不做遥测；指标只存本机。

## 性能

看板的计算结果在 `DashboardStore` 里后台算好并缓存，body 只读结果；`DayKey` 不用 `DateFormatter`。改动看板后用下面的命令复测，切换操作应在 100 ms 内：

```bash
TOKEN_VOYAGE_DATA_DIR=/tmp/voyage-measure build/TokenVoyage.app/Contents/MacOS/TokenVoyage --measure-dashboard
```

## 验证

```bash
cd voyage && swift test
cd voyage && scripts/build-app.sh
open voyage/build/TokenVoyage.app
```
