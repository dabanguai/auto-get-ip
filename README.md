# auto-get-ip

自动获取本机 IP 并通过多种渠道推送到个人或群（企业微信/PushPlus/Telegram），方便在 IP 经常变化时让前端同事或自己快速拿到当前可访问的 IP【供个人使用】。

## 功能概览

- 获取公网 IP（多接口兜底）：
  - https://api.ipify.org
  - https://ipinfo.io
  - https://ifconfig.me
- 获取本机所有 IPv4 内网 IP（排除 127.0.0.1）。
- 多种推送方式（按优先级）：
  1. 企业微信群机器人 Webhook（`webhook`）
  2. PushPlus 推送给个人或群（`pushplus_token`）
  3. Telegram Bot 推送消息（`telegram_token` + `telegram_chat_id`）
  4. 企业微信自建应用发送应用消息给个人（`corp_id` 等）
- 支持在以下时机自动推送：
  - 用户登录 Windows 时
  - 屏幕解锁（Workstation Unlock）时

## 项目结构

- `send-ip.ps1`：核心逻辑脚本，负责获取 IP 和推送消息。
- `config.json`：配置文件，存放推送渠道相关参数（token、Webhook 等）。
- `install-task.ps1`：通过 Windows 计划任务注册自动执行 `send-ip.ps1` 的任务（登录、解锁时触发）。

## 配置说明（config.json）

示例：

```json
{
  "webhook": "",
  "extraText": "",
  "pushplus_token": "",
  "telegram_token": "",
  "telegram_chat_id": "",
  "corp_id": "",
  "corp_secret": "",
  "agent_id": "",
  "wecom_userid": ""
}
```

字段含义：

- `webhook`：企业微信群机器人 Webhook 地址。
  - 若配置了该字段，将优先使用群机器人推送。
- `extraText`：附加的文本信息，会追加在消息最后一行。
- `pushplus_token`：PushPlus 的 token，用于给个人或群推送。
- `telegram_token`：Telegram Bot 的 token（通过 BotFather 创建）。
- `telegram_chat_id`：Telegram 的聊天 ID，可以是个人或群。
- `corp_id`：企业微信企业 ID。
- `corp_secret`：企业微信自建应用的 Secret。
- `agent_id`：企业微信自建应用的 AgentId。
- `wecom_userid`：企业微信中你的用户 ID，用于指定接收人。

> 注意：所有敏感配置（token、secret）仅保存在本地，不要提交到公共仓库或分享给他人。

## send-ip.ps1 逻辑说明

1. **获取公网 IP**
   - 函数 `Get-PublicIp` 依次调用 3 个公网 IP 接口：
     - `https://api.ipify.org?format=json`
     - `https://ipinfo.io/ip`
     - `https://ifconfig.me/ip`
   - 每个接口设置了 `TimeoutSec 10`，并使用 `try/catch` 忽略单次失败。
   - 任意接口返回成功即使用该 IP，否则返回空字符串。

2. **获取内网 IP**
   - 函数 `Get-LocalIps` 优先使用：
     - `Get-NetIPAddress -AddressFamily IPv4` 过滤掉 `127.0.0.1`，并且 `PrefixLength < 32`。
   - 若该命令在当前系统不可用或报错，则降级为：
     - `Get-WmiObject Win32_NetworkAdapterConfiguration`，筛选 `IPEnabled = $true` 的网卡，取其 IPv4 地址。
   - 所有得到的 IPv4 地址用 `, ` 拼接为字符串。

3. **加载配置**
   - 函数 `Load-Config` 从脚本所在目录读取 `config.json`。
   - 若文件不存在或 JSON 解析失败，返回 `$null`。

4. **拼接消息内容**
   - 从系统环境变量读取计算机名：`$env:COMPUTERNAME`。
   - 获取当前时间：`Get-Date -Format "yyyy-MM-dd HH:mm:ss"`。
   - 消息格式：
     - `时间: <time>`
     - `主机: <machine>`
     - `公网IP: <public ip>`
     - `内网IP: <local ips>`
     - 如果配置了 `extraText`，再追加一行。

5. **推送渠道实现**
   - `Push-WeComWebhook($url, $content)`：
     - 对企业微信群机器人 Webhook 发送 `{"msgtype":"text","text":{"content":"..."}}`。
   - `Push-PushPlus($token, $content)`：
     - POST 到 `https://www.pushplus.plus/send`。
     - 请求体：`{ token, title: "IP通知", content, template: "txt" }`。
     - 若返回 `code != 200`，在控制台打印错误信息。
   - `Push-Telegram($token, $chatId, $content)`：
     - `https://api.telegram.org/bot<token>/sendMessage`。
     - Body：`{ chat_id, text }`。
   - `Push-WeComApp($corpId, $corpSecret, $agentId, $userId, $content)`：
     - 先调用 `gettoken` 获取 `access_token`。
     - 再向 `message/send` 接口发送文本消息给指定 `touser`。

6. **推送渠道选择顺序**
   - 脚本会按以下优先级选择第一个可用的渠道进行推送：
     1. `webhook`（企业微信群机器人）
     2. `pushplus_token`（PushPlus）
     3. `telegram_token` + `telegram_chat_id`（Telegram Bot）
     4. `corp_id` + `corp_secret` + `agent_id` + `wecom_userid`（企业微信自建应用）
   - 若所有渠道配置都不可用，则在控制台输出：`No push channel configured`。

## install-task.ps1 逻辑说明

该脚本用于在 Windows 中注册计划任务，在以下时机自动执行 `send-ip.ps1`：

- 用户登录时（Logon）
- 工作站解锁时（Session Unlock）

主要步骤：

1. 设置错误行为为抛出异常：`$ErrorActionPreference = "Stop"`。
2. 若未传入 `$TaskName`，则使用默认名称 `SendIPToWeCom`。
3. 拼出目标脚本路径：`$PSScriptRoot\send-ip.ps1`。
4. 若脚本不存在则退出并提示。
5. 构造计划任务执行参数：
   - 调用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scriptPath>"`。
6. 定义执行动作：`New-ScheduledTaskAction`。
7. 创建两个触发器：
   - 登录触发：`New-ScheduledTaskTrigger -AtLogOn -User $env:UserName`。
   - 解锁触发：
     - 通过 `Get-CimClass` 获取 `MSFT_TaskSessionStateChangeTrigger`。
     - 新建实例并设置 `StateChange = 8`（会话解锁）。
8. 指定任务以当前交互用户身份运行：`New-ScheduledTaskPrincipal`。
9. 设置任务行为：
   - `StartWhenAvailable`：错过触发时间会尽快补跑。
   - `AllowStartIfOnBatteries` / `DontStopIfGoingOnBatteries`：在笔记本电池状态下也允许运行。
10. 若存在同名任务，先通过 `Unregister-ScheduledTask` 删除。
11. 调用 `New-ScheduledTask` 组合动作、触发器、设置与主体。
12. 用 `Register-ScheduledTask` 注册到系统中。

## 使用步骤

### 1. 安装 PowerShell 脚本

将项目放在任意目录，例如：

- `D:\project\auto-get-ip`

确保你可以在该目录中执行 PowerShell 脚本。

### 2. 配置 PushPlus（推荐）

1. 在 PushPlus 官网注册并登录。
2. 获取你的 `token`。
3. 在 `config.json` 中：
   - `webhook` 保持为空字符串 `""`（否则会优先走企业微信机器人）。
   - 将 `pushplus_token` 设置为你的 token。
4. 保存 `config.json`。

### 3. 本地测试推送

在项目目录下打开 PowerShell，运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\send-ip.ps1
```

预期：

- 控制台无错误输出（PushPlus 成功时可无提示或仅简单日志）。
- PushPlus 后台「消息历史」中可以看到一条新消息。
- 若你已按官方指引绑定/关注服务号，则可在微信中收到推送。

### 4. 注册自动推送计划任务

方式一：使用脚本（推荐）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-task.ps1
```

成功后：

- 在「任务计划程序」中会看到名称为 `SendIPToWeCom` 的任务。
- 每次登录或解锁都会自动执行 `send-ip.ps1` 并推送 IP。

方式二：手动创建任务（可选）
1. 打开「任务计划程序」，新建任务。
> 任务计划程序库 -> Microsoft -> windows -> TaskScheduler -> 创建任务
2. 配置项
- 触发器：【登录时】
- 操作
  - 操作：【启动程序】
  - 程序或脚本：【`powershell.exe`】
    - 添加参数：【`-ExecutionPolicy Bypass -File "D:\project\auto-get-ip\send-ip.ps1"`】（可自行修改路径）
```

> 提示：解锁触发依赖安全日志中的事件 4801，可能需要在本地安全策略中开启相应的审计项。

## 常见问题

### 计划任务没有触发推送

- 检查 `config.json` 是否至少配置了一个可用的推送渠道。
- 在「任务计划程序」中右键任务，选择「运行」，看是否能正常执行。
- 手动在 PowerShell 中运行 `send-ip.ps1` 观察是否有错误输出。

### PushPlus 没有在微信收到消息

- 确认 PushPlus 后台「消息历史」中是否有记录。
- 确认是否已经按照官方提示绑定并关注服务号。
- 检查 `pushplus_token` 是否填写正确且没有额外空格。

### 想改为系统启动触发而不是登录/解锁

- 可以单独创建一个 `ONSTART` 触发的计划任务，命令行与本项目相同。
- 需要注意系统启动时网络可能尚未完全可用，建议在任务属性中增加启动延迟或重复执行策略。

## 安全建议

- 不要将 `config.json` 提交到公共仓库。
- 不要在公共场合展示 PushPlus token、企业微信 Secret、Telegram Bot token 等敏感信息。
- 若怀疑 token 泄露，应立即在对应平台重置或删除。

