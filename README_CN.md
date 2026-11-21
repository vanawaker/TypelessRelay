# TypelessRelay

[English](README.md) | **简体中文**

> 专为双 Mac **屏幕共享（Screen Sharing）** 打造的 **Typeless 跨屏语音无感秒贴挂件** —— 告别多余的字母 `v`，告别烦人的底部复制弹窗。

**TypelessRelay** 是一个单文件原生 Swift 菜单栏小工具（Apple Silicon + Intel 通用二进制，自动跟随系统语言切换中/英文界面）。当你把麦克风和 **Typeless** 装在主力 Mac 上，同时通过 macOS 自带「屏幕共享」（或 Luna Display / Apple Remote Desktop / UU 远程）控制另一台副 Mac 时，它能让副屏里的语音输入像在本机一样丝滑直出。

---

## 解决什么痛点？

在主力 Mac 上按 `Fn` 对着「屏幕共享」窗口说话时，原生会同时触发两个问题：

1. **副 Mac 输入框里只蹦出一个孤零零的小写 `v`**
   - Typeless 底层上屏并不是逐字敲击，而是先将转写文本写入主力机剪贴板（附加 `org.nspasteboard.TransientType` 标记），再发送一个单 `v` 键合成事件并挂上 `kCGEventFlagMaskCommand` 标志位（**没有**发送独立的 `Command` 键按下/抬起硬件事件），500 ms 后还原主力机剪贴板。
   - macOS 屏幕共享（`RFBEventHelperd`）同步修饰键依赖真实的修饰键按下动作，会直接吃掉该合成标志位，只把一个裸奔的小写 `v` 发给副 Mac，而副 Mac 也根本来不及同步到剪贴板文本。
2. **每次说完话底部都会弹出手动复制卡片**
   - 对主力机的辅助功能 API 而言，屏幕共享窗口只是一整块不透明视频画布（`is_editable == false`）。Typeless 内置的 `app_whitelist` 给 Windows 远控工具（`RDCMan.exe`、`mRemoteNG.exe`）开了白名单，却漏掉了 macOS 的 `com.apple.ScreenSharing`。

---

## 工作原理

在局域网内的两台 Mac 上安装同一个超轻量的 `TypelessRelay.app`：

- **局域网零配置自动互发现**：按真实物理网卡绑定 `IP_BOUND_IF` 的 UDP 子网广播（端口 `52972`，彻底绕开代理/VPN TUN 虚拟网卡默认路由劫持，双网卡自动稳定锁定主通道）+ 单播心跳保活，启动毫秒级自动配对。
- **顶栏一键互选角色**：在任意一台 Mac 的菜单栏里点选 **「本机作为接收端」** 或 **「发射到 → `<目标 Mac>`」**，单边点选双端自动联动，并持久化记住上次配置。
- **发射端（插着麦克风、运行 Typeless 的主力 Mac）**：
  - **仅在**「屏幕共享 / Luna Display / UU 远程 / Apple Remote Desktop」处于前台时激活，主力机日常使用完全无感透明。
  - 将主动 `CGEventTap` 挂载在 `kCGHIDEventTap` 末端（卡在屏幕共享 `RFBEventHelperd` 之前）。
  - 通过内核事件源进程号 `eventSourceUnixProcessID` 精准识别 Typeless 合成粘贴事件，当场吞掉多余的 `v`，并将纯文本与富文本 HTML 通过局域网 TCP 直连（端口 `52971`，`<40 ms`）推给副机。
  - 启动及定期自动维护 `~/Library/Application Support/Typeless/app-storage.json` 里的远控窗口白名单（首次修改前自动备份 `.bak`），从源头阻止底部复制框在屏幕共享内弹出，同时保留主力机桌面等无输入框场景的原有弹窗。
- **接收端（被控制的副 Mac）**：
  - 收到文本后备份当前剪贴板 → 写入语音文本 → 发送完整四步原生 `按下 Cmd → 按下 V → 抬起 V → 抬起 Cmd`（绝不残留修饰键卡死状态）→ 380 ms 后无痕还原原剪贴板。

---

## 构建与安装

系统要求：macOS 13 及以上，需安装 Xcode Command Line Tools（`xcode-select --install`）。

```bash
git clone https://github.com/vanawaker/TypelessRelay.git
cd TypelessRelay

# 1. 编译通用二进制（arm64 + x86_64）到 build/TypelessRelay.app
./scripts/build.sh

# 2. 安装并启动到本机 /Applications
./scripts/install_local.sh

# 3. 可选：通过 SSH 一键部署并启动到局域网另一台 Mac
./scripts/deploy_remote.sh user@other-mac.local
```

> **自用小技巧**：可在项目根目录新建被 `.gitignore` 忽略的 `.env.local`，写入 `TYPELESSRELAY_REMOTE="user@你的另一台Mac"`，之后直接执行 `./scripts/deploy_remote.sh` 即可免参一键部署，不向仓库泄露个人地址。

### 稳定自签证书（可选）

默认采用 ad-hoc 签名（`-`），每次重编译二进制 `cdhash` 变化会导致 macOS 重置辅助功能授权（安装脚本会自动 `tccutil reset Accessibility` 清理旧条目，确保弹窗干净）。如果你频繁重编译，可在「钥匙串访问」创建自签代码签名证书并通过环境变量指定：

```bash
export TYPELESSRELAY_SIGN_IDENTITY="你的自签证书名"
./scripts/build.sh
./scripts/install_local.sh
```

---

## 权限与首次使用

1. 在两台 Mac 上分别启动 **TypelessRelay**。
2. 在两台 Mac 的 **系统设置 → 隐私与安全性 → 辅助功能** 中打开 **`TypelessRelay`** 开关，无需重启应用即可生效，状态栏图标会自动切换：
   - `声波 !` — 尚未授予辅助功能权限
   - `声波 ↗` — 发射端已就绪并锁定目标
   - `声波 ↙` — 接收端已就绪待命
3. 点开主力机菜单栏图标确认已勾选 **「发射到 → `<你的副 Mac>`」**，按需勾选两边菜单中的 **「开机自启」** 即可。

> **独立白名单补丁脚本**：发射端运行时会自动巡检维护 Typeless 白名单；如曾退出重登或重装 Typeless 需手动补打，可在主力机单独执行 `./scripts/patch_typeless_whitelist.py`。

---

## 姐妹项目

如果你在双 Mac 屏幕共享下还被 macOS 反复弹窗「允许 ScreensharingAgent 启用第三方输入法」折磨，推荐搭配 **[CapsRelay](https://github.com/vanawaker/CapsRelay)** 一起使用，彻底解决屏幕共享下按 `Caps Lock` 切换第三方输入法的问题。

---

## 说明

本工具最初为个人双 Mac 屏幕共享工作流编写，按原样开源分享，不保证长期响应所有 Issue。由于依赖 Typeless 当前的剪贴板标记与白名单配置结构，若未来 Typeless 官方原生修复屏幕共享粘贴问题，本工具即可功成身退。

## 许可证

[MIT](LICENSE)
