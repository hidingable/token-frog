# Voyage 技术方案

## 实现交接

新会话从这里开始。产品规则以 [design.md](design.md) 为准，界面以 [mockup.html](mockup.html) 为准。开发在 `feat/voyage` 分支上进行。

### 当前代码和设计的差距

| 位置 | 现状 | 要改成 |
|---|---|---|
| `LetterComposer` | M0 模板渲染旧信 | 新信用内容包的正文，旧信继续用模板 |

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
3. **周日长信：** 本周里程、工具、趋势和一件大事回顾；信箱显示明信片和长信分类。
4. **本周心愿：** 邮局心愿卡，关键词解析标签，有本机模型时再选标签；接通抽站和情节加权，关联不到时信里说明。
5. **足迹和途中线索：** 旅途页的最常去、最远、最难忘；每天最多一条途中线索。
6. **用量事件：** 超过中位数 2 倍、深夜、第一次用某工具（船票），都不带额外奖励。
7. **幼年和少年形态：** 四个角色的外形按阶段变化，以及少年的邮局布置。
8. **重游故事：** 3 条线索解锁，补全城市资料。

M3、M4 和异步偶遇不要提前做，但数据结构要给它们留位置。M2 之后做在线内容包；正式签名、公证和应用自动更新等 Developer ID 和 Sparkle 决定后再做。

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
工具日志 → tokscale graph → UsageSource（解析燃料）
        → JourneyState.sync（确定性推进）→ journey.json
        → AppModel → 刘海 / 浮窗 / 主窗口
新信 → Enricher（天气、Wikipedia、像素照片）→ journey.json
tokscale graph / hourly → UsageDashboard（趋势、活跃、明细）→ 看板，只用于显示，不进入旅程
```

## 引擎不变量

- **整数记账：** 进度用 token 整数保存，不用浮点公里，不产生累计误差。
- **确定性：** 相同种子和相同用量序列得到相同旅程。下一站的随机结果由种子加已到站数决定。
- **只增不减：** 当天统计值下降时不回退里程。
- **精确增量：** 每次只推进"新值 − 已记录值"。
- **跨天结算：** 先用前一天的最终值补差，再结算，已结算的日子不再改动。应用关闭多日后，逐日补算。
- **航段快照：** 抽到下一站时把距离和两端坐标写进存档，内容包修改坐标或删除城市都不影响已保存的路线和进度。
- **信件 enrich 失败不影响旅程：** 信件先由模板生成，网络内容是可选的补充。

## 养成引擎（M1 起）

养成是 `VoyageCore` 里独立于 `JourneyState` 的纯逻辑。旅程只产出已结算的信和事件；养成消费它们，不反向影响里程。

- **用量无关：** 习惯、形态、掉落和故事选择的输入不含 token 数。测试固定：用量翻倍，结果不变。
- **确定性：** 掉落和情节由 `seed`、信件序号、到达的城市、习惯、工具和保底计数决定，补算多日不会改变结果。实时天气不参与选择，雨中故事按城市资料里的雨季触发。
- **幂等：** 按信件序号和日期记账，重复处理不会重复发放。
- **兑现时机：** 只由种子、信件序号和回应决定，不看到了哪座城。到期后才选能兑现的情节。
- **下一站：** 由引擎按距离档、是否去过和心愿标签随机抽取，结果由种子决定，玩家不选。抽站基准不含到站当天，否则结果会随扫描时机变化。
- **心愿解析：** 只在本机运行，优先 Foundation Models，不可用时按关键词匹配城市和物品标签；关联不到就随机。
- **偏离事件：** 比较当天用量和近 14 天中位数；深夜事件用扫描时的增量时间戳，应用未运行时不补发。

## 内容包（M1 起）

城市、情节、物品和文案都是数据。代码只认结构，加内容不改代码。

### 目录

```text
voyage/Content/
├── manifest.json        版本和兼容信息
├── tags.json            统一标签表
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

`kind` 是 `arrival`、`transit`、`fulfill`、`postcard` 或 `reunion`。后两类必须是无条件、无城市的通用内容，不设回应、兑现或指定奖励；其 `text` 可直接独立成文，另用双语 `memoryLead`（含 `{memory}`，可含 `{pet}`）作为有记忆时才加入的引句。它们的正文只支持 `{pet}`，不使用城市事实。旧物和重逢礼在 `items/` 中用 `source: "postcard"` / `"reunion"` 分池，前者每种稀有度都有候选，后者固定普通。其余旅行情节的正文可以带 `{pet}`、`{city}`、`{target}`、`{reply}` 槽位，生成信时填好；槽位不能拼接语法，比如英文复数要写成完整句子。

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
- **选择情节的顺序：** 到期的兑现 → 符合工具和季节 → 符合习惯 → 符合心愿标签 → 该城通用 → 无资料模板。同级用种子随机，并避开最近 10 封用过的。
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

## Voyage Hub：异步偶遇（规划）

默认关闭，用户明确开启后才联网。Voyage Hub 是 Voyage 自己的服务，负责偶遇和同步，和 Token Monitor 的 Hub 没有关系。单人玩法不需要它。

技术选型开发时再定；要求是能按量扩展、有匿名限流、能完整删除数据。

### 原则

- **最小数据：** 只发城市、当地点位、日期、角色外观、习惯标签，以及足迹和收藏的内容 ID。
- **绝不上传：** token 数、费用、工具、模型、项目、会话、精确时间、邮箱、宠物名和本机路径。
- **没有自由文本：** 问候和留言都用预设短语 ID，不需要内容审核。
- **匿名身份：** 设备生成 Ed25519 密钥放进钥匙串，请求用它签名，没有账号。
- **防作弊：** 开启后存档绑定这个设备密钥并定期同步。服务端按日期校验（比如一天最多一次停留）、拒绝不存在的内容 ID。这只能挡住随意改存档，挡不住改客户端；用量不上传，所以不校验里程。
- **离线优先：** 请求失败时信照常写。偶遇只增加内容，不影响里程、习惯、形态和掉落。

### 接口草案

所有路径带版本，字段只增不改，写入都带客户端生成的 ID 以便安全重试。

| 接口 | 作用 |
|---|---|
| `PUT /v1/sync` | 定期同步足迹和收藏的内容 ID，用于校验和换设备恢复；同步失败下次再试 |
| `POST /v1/visits` | 登记当天落脚的城市和点位。一天最多一次，所以用得多的人不会遇到更多人 |
| `GET /v1/places/{cityId}/footprints?cursor=` | 读取该点位近期其他旅人留下的脚印 |
| `POST /v1/greetings` | 对一个脚印发送预设问候 |
| `GET /v1/inbox?cursor=` | 读取收到的问候、留影邀请和访客 |
| `POST /v1/visitors/{visitId}/gift` | 访客来访时复制一件对方公开摆出的纪念品；只传内容 ID，原件不减少 |
| `POST /v1/postcards` | 发起双签明信片 |
| `POST /v1/postcards/{id}/confirm` | 另一方同意后才生成 |
| `DELETE /v1/me` | 删除这个匿名身份的全部数据 |

```json
{
  "visitId": "018f…",
  "cityId": "quanzhou",
  "spotId": "xunpu",
  "day": "2026-11-06",
  "appearance": { "species": "pigeon", "stage": "traveler" },
  "habits": ["talkative"],
  "footprintPhraseId": "keep-half-crisp"
}
```

只有上面的内容会离开本机。到访记录保留期限要在上线前确定。

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
