# GameCase

> 导入 IPA 与数据包，打开就玩

GameCase 是一个专为 iOS 移植游戏设计的侧载游戏容器。它基于开源项目 LiveContainer 定制，砍掉通用 App 容器的旁支功能，只保留一件事：把移植游戏装进一个游戏库里——导入、封面、设置、启动、切换，全在库内完成。

游戏在容器进程内全屏直跑，串行单开；玩完一款，从游戏内快捷栏回到游戏库再开下一款，上一个游戏的进程随之关闭，不留后台。免越狱，侧载即用。

## 它做对了什么

**像游戏机一样选游戏**
游戏库效仿 NX2Apple 壳界面：横屏是封面色调背景加卡片轮播，竖屏是封面大图、最近游玩与游玩时长、底部开始胶囊。打开 GameCase 不是面对一列文件，而是站在自己的游戏架前。

**游戏和数据包，分开导入**
移植游戏的 IPA 与 romfs 数据包（romfs.img）各走各的通道：数据包导入时校验大小后写入对应游戏的容器，游戏更新只换 IPA，几个 G 的数据包不用重下。

**设置项，游戏自己说了算**
每款游戏的设置直接来自它自带的启动器档案（dm/launcher.json）：帧率、画面模式、超分、皮肤——游戏有什么，这里就有什么，不多一项不少一项。库内修改与游戏内修改双向同步，下次启动生效。设置页是 NX 式整页：大封面头加分段控件。

**装进去，点开就进游戏**
单装版游戏 IPA 导入后，点封面直接进游戏，不再弹客体启动页；想保留启动页的游戏，在其设置页打开「显示游戏启动页」即可。

**云存档，换设备接着玩**
在设置里选好云文件夹，存档自动同步：GameCase、单装版、NX2Apple 壳与电脑共用同一套云存档格式，在哪边玩都能接上进度。冲突时保留较新的一份，旧的自动备份。

**Mod 与金手指**
每款游戏有自己的 Mod 组：把散装 Mod 放入对应位置即自动接线，启动生效。金手指导入氛围（Atmosphère）格式文件，逐条开关，数据型修改真实生效。

**封面，不用你操心**
优先用 IPA 自带横版图；有官方主视觉的，按游戏 ID 从任天堂商店自动抓取 1920×1080 封面；也可以换成你自己的图，或随时恢复默认。

**容器夹，就是游戏名**
每款游戏的数据容器文件夹以游戏名命名（`Data/Application/<游戏名>/`）。在「文件」App 里手动放数据包、管存档时，一眼就知道哪个夹是哪款游戏。

**快捷栏一键回库，只开一款所以稳**
游戏内顶部吸附一条半藏的玻璃舌，可沿上边拖动、落点记忆；点开是完整快捷栏，一键返回游戏库（带淡出过场）。串行单开不做多任务，全部性能留给正在运行的游戏——对移植游戏来说，这才是正经事。

**内存，给满**
默认开启系统游戏模式：容器里的游戏与单装享有同样的内存上限，不因装在容器里少一截。

**手柄与证书**
手柄页实时列出已连接手柄与电量状态（按 NX2Apple 的 Controllers 页移植）；容器设置里导入与签名同团队的开发者证书后，可免 JIT 运行。

## 截图

![横屏游戏库](docs/media/library-landscape.jpg)

横屏游戏库：封面牌组，中间为当前选中的游戏。

![竖屏游戏库主页](docs/media/library-portrait.jpg)

竖屏游戏库主页：大封面、「你的游戏」网格、「最近游玩」与底部的开始按钮。

![游戏设置页](docs/media/game-settings.jpg)

游戏设置页（以撒）：显示分组，含主机模式、超分、游戏语言与帧数计数器。

## 三步开玩

1. 侧载安装 GameCase，并在容器设置里导入证书；
2. 导入游戏 IPA 与对应数据包（romfs.img）；
3. 点封面，开玩。

## 装机须知

- **签名证书要求**：GameCase 须以开发者证书（Development Certificate）签名安装。市面在售证书多为分发证书（Distribution Certificate）或企业证书（Enterprise Certificate）：以此类证书签名，应用打开时将提示「未使用开发者证书签名」，且游戏无法正常启动。购买证书前，请务必向商家确认证书类型为开发者证书。签名方式可使用 [LCSign](https://www.sign.lc) 导入证书签名，或以个人 Apple ID 通过 [SideStore](https://sidestore.io) / [AltStore](https://altstore.io) 免费签名安装（个人签名同为开发者证书）。
- **全新 App 身份**：GameCase（`com.tiaoge.gamecase`）在系统眼里是一个全新 App，与旧 LiveContainer 并存、互不影响。首次使用需重新导入证书、游戏 IPA 与数据包各一次；确认一切正常后，可删除旧容器。
- **签名标识必须与证书对齐**：签名工具里改用的标识要与证书的 App ID 一致，否则会出现文件选择器点不动/无回调、数据包选不了、证书导入失败等问题。本仓库 Release 提供未签名 IPA，请用自己的开发者证书签名安装，并作为新项目导入签名工具，不要复用被第三方签名服务改过标识的旧项目。
- **数据包手动放置**：也可以不用 App 内导入，直接在「文件」App 里把 `romfs.img` 放进 `GameCase → Data → Application → <游戏名> → Documents` 文件夹内（注意是游戏容器夹里面的 Documents，不是放在容器夹根目录）。
- **免 JIT 模式**：在容器设置中导入与签名容器本体同一团队的证书，团队不一致会被挡下。

## SideStore 版使用说明

Release 同时提供 `GameCase+SideStore.ipa`：内置了完整的 SideStore，整个应用只占一个免费签名名额。它的用处是**内签**——在手机上用你的 Apple ID 给 GameCase 本体续签、更新，以及签名安装其它应用，全程不需要电脑。

### 首次设置

1. 在 GameCase「设置」页点「打开内置 SideStore」，在它的设置中登录 Apple ID，并连接 LocalDevVPN。
2. 在内置 SideStore 的设置页进入「Pairing File Management（配对文件管理）」，点「Wireless Pairing（无线配对）」，保持 LocalDevVPN 连接即可在手机上完成配对、生成配对文件，全程不需要电脑。配对文件只需生成一次，之后的刷新都走它。
3. 到「My Apps」页点一次「Refresh All」。
4. 回到 GameCase「设置」页点「从 SideStore 导入证书」，按钮变为「移除证书」即已打通，免 JIT 模式随之可用。

### 免 JIT 的证书前提（重要）

免 JIT 只认**开发（Development）证书**，且导入 GameCase 的证书必须与**签 GameCase 本体的证书同团队**，两条缺一不可：

- **免费 Apple ID**：登录内置 SideStore 生成的个人团队开发证书可用，但前提是 GameCase 本体也是同一个 ID 签的——先在内置 SideStore 里把本体刷新成该 ID 的签名，再点「从 SideStore 导入证书」。
- **付费开发者证书**：可以，本体与导入须同团队。
- **分发（Distribution）证书**：签的本体无法使用免 JIT（会提示「未被使用开发证书签名」），请改用开发证书签名，或使用 JIT 模式。

### 登录报 -80045

`This action cannot be completed at this time (-80045)` 是苹果 2026 年 10 月起收紧登录校验的结果（递交的设备身份与自报信息不一致），与账号密码无关。改一次设置即可，改完后刷新、注册都走这套配置（以下按 GameCase 内置版的中文界面）：

1. 「设置」→「用户自定义」：关掉「设备端 Anisette」，点「立即重启」。
2. 「设置」→「Anisette 服务器」：选 SideStore (new)，关掉「启用自动轮换」。
3. 「用户自定义」→「Anisette 客户端配置」→「远程服务器同步」→「另存为覆盖项」，再「保存覆盖项」。同步失败就手动填 Client Info `<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>`、User Agent `akd/1.0 CFNetwork/808.1.4`。
4. 「用户自定义」→「重置 adi.pb」。
5. 重新登录；双重验证用其他苹果设备上弹出的验证码，不要等短信。

### 日常使用

- **返回 GameCase**：在内置 SideStore 的「My Apps」页点左上角的退出（escape）图标即可回库（或用应用切换器）。News 页条目上的 OPEN 不是返回入口，点了不会有反应。
- **续签**：免费证书临近到期时，打开内置 SideStore 点「Refresh All」即可为 GameCase 本体续签。
- **更新**：把新版 GameCase 的 IPA 在内置 SideStore 中安装即覆盖更新，游戏与数据保留。

## 致谢与开源来源

GameCase 站在以下开源工作之上，特此致谢：

- **[LiveContainer](https://github.com/LiveContainer/LiveContainer)** —— 本项目的底座（在容器内免安装运行 iOS 应用的启动器）。原作者 **Duy Tran（[khanhduytran0](https://github.com/khanhduytran0)）**，主要维护者 **[hugeBlack](https://github.com/hugeBlack)**，以及 LiveContainer 组织与众多贡献者。本项目完整继承其代码与 git 历史，并沿用同一许可证 **GNU AGPL v3.0**（见仓库根目录 `LICENSE`）。上游原 README 全文保留于 [docs/livecontainer-readme.md](docs/livecontainer-readme.md)。
- **[nxnative](https://github.com/seedds/nxnative)**（作者 **[seedds](https://github.com/seedds)**）—— 客体游戏移植的工具链与生态来源：GameCase 中运行的移植游戏 IPA 由 nxnative 产出（NSO 重写、Horizon HLE、NVN→Metal）。
- **[NX2Apple](https://github.com/LNPANDY/NX2Apple)**（作者 **[LNPANDY](https://github.com/LNPANDY)**）—— 设计参考来源：游戏库界面的效仿对象、其壳的手柄设置页（Controllers）被移植进 GameCase，其一壳多游戏的思路亦为本项目的参照。

## 声明

- GameCase 本身**不包含任何游戏内容**。游戏 IPA 与数据包（romfs.img）需由用户自备，并请确保来源合法。
- 相关游戏的版权归各原厂所有，本项目与上述原作者、团队及游戏厂商均无隶属关系。
- 本项目按 GNU AGPL v3.0 发布；若你分发修改版，请同样以 AGPL-3.0 开源并保留上述归属。

## 链接

- 本项目：[Tiaoge-tou/GameCase](https://github.com/Tiaoge-tou/GameCase)
- 下载（nightly）：[Releases](https://github.com/Tiaoge-tou/GameCase/releases)
- 上游底座：[LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer)
- 上游原 README（归档）：[docs/livecontainer-readme.md](docs/livecontainer-readme.md)
- 许可证：[LICENSE](LICENSE)
