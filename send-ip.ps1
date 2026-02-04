$ErrorActionPreference = "Stop"
# 获取公网IP，依次尝试多个免费接口，避免单点失败
function Get-PublicIp {
    try {
        $r = Invoke-RestMethod -UseBasicParsing -Uri "https://api.ipify.org?format=json" -TimeoutSec 10
        if ($r.ip) { return $r.ip }
    } catch {}
    try {
        $r2 = Invoke-RestMethod -UseBasicParsing -Uri "https://ipinfo.io/ip" -TimeoutSec 10
        if ($r2) { return ($r2 -as [string]).Trim() }
    } catch {}
    try {
        $r3 = Invoke-RestMethod -UseBasicParsing -Uri "https://ifconfig.me/ip" -TimeoutSec 10
        if ($r3) { return ($r3 -as [string]).Trim() }
    } catch {}
    return ""
}
# 获取本机所有非回环IPv4地址（内网IP）
function Get-LocalIps {
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixLength -lt 32 } | Select-Object -ExpandProperty IPAddress
        if ($ips) { return ($ips -join ", ") }
    } catch {
        try {
            $ips = (Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true } | ForEach-Object { $_.IPAddress } | Where-Object { $_ } | ForEach-Object { $_[0] }) | Where-Object { $_ -ne "127.0.0.1" }
            if ($ips) { return ($ips -join ", ") }
        } catch {}
    }
    return ""
}
# 从脚本所在目录加载配置文件 config.json
function Load-Config {
    $cfgPath = Join-Path $PSScriptRoot "config.json"
    if (-not (Test-Path $cfgPath)) { return $null }
    try {
        $json = Get-Content -Path $cfgPath -Raw | ConvertFrom-Json
        return $json
    } catch { return $null }
}
$cfg = Load-Config
$pub = Get-PublicIp
$loc = Get-LocalIps
$machine = $env:COMPUTERNAME
$time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$extra = ""
if ($cfg -and $cfg.extraText) { $extra = $cfg.extraText }
$content = "时间: $time`n主机: $machine`n公网IP: $pub`n内网IP: $loc"
if (-not [string]::IsNullOrWhiteSpace($extra)) { $content = "$content`n$extra" }

# 企业微信群机器人推送
function Push-WeComWebhook($url, $content) {
    $body = @{ msgtype = "text"; text = @{ content = $content } }
    try { Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Body (ConvertTo-Json $body -Depth 5) | Out-Null } catch {}
}
# PushPlus 推送给个人或群（按官方示例：UTF-8 字节 + application/json）
function Push-PushPlus($token, $content) {
    $bodyObj = @{
        token    = $token
        title    = "IP通知"
        content  = $content
        template = "txt"
    }

    $json = $bodyObj | ConvertTo-Json -Depth 5

    try {
        $res = Invoke-RestMethod `
            -Method Post `
            -Uri "https://www.pushplus.plus/send" `
            -ContentType "application/json; charset=utf-8" `
            -Body $json `
            -ErrorAction Stop

        if ($res -and $res.code -ne 200) {
            Write-Output ("PushPlus失败: " + $res.msg)
        }
    } catch {
        Write-Output ("PushPlus调用错误: " + $_.Exception.Message)
    }
}

# Telegram Bot 推送
function Push-Telegram($token, $chatId, $content) {
    $url = "https://api.telegram.org/bot$token/sendMessage"
    $body = @{ chat_id = $chatId; text = $content }
    try { Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Body (ConvertTo-Json $body -Depth 5) | Out-Null } catch {}
}
# 企业微信自建应用推送应用消息给个人
function Push-WeComApp($corpId, $corpSecret, $agentId, $userId, $content) {
    try {
        $tRes = Invoke-RestMethod -UseBasicParsing -Uri ("https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=" + $corpId + "&corpsecret=" + $corpSecret)
        if (-not $tRes.access_token) { return }
        $body = @{ touser = $userId; agentid = [int]$agentId; msgtype = "text"; text = @{ content = $content }; safe = 0 }
        Invoke-RestMethod -Method Post -Uri ("https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=" + $tRes.access_token) -ContentType "application/json" -Body (ConvertTo-Json $body -Depth 5) | Out-Null
    } catch {}
}
$pushed = $false

# 渠道选择优先级：群机器人 > PushPlus > Telegram > 企业微信自建应用
if ($cfg -and $cfg.webhook -and -not [string]::IsNullOrWhiteSpace($cfg.webhook)) {
    Push-WeComWebhook $cfg.webhook $content
    $pushed = $true
} elseif ($cfg -and $cfg.pushplus_token -and -not [string]::IsNullOrWhiteSpace($cfg.pushplus_token)) {
    Push-PushPlus $cfg.pushplus_token $content
    $pushed = $true
} elseif ($cfg -and $cfg.telegram_token -and $cfg.telegram_chat_id -and -not [string]::IsNullOrWhiteSpace($cfg.telegram_token) -and -not [string]::IsNullOrWhiteSpace($cfg.telegram_chat_id)) {
    Push-Telegram $cfg.telegram_token $cfg.telegram_chat_id $content
    $pushed = $true
} elseif ($cfg -and $cfg.corp_id -and $cfg.corp_secret -and $cfg.agent_id -and $cfg.wecom_userid -and -not [string]::IsNullOrWhiteSpace($cfg.corp_id) -and -not [string]::IsNullOrWhiteSpace($cfg.corp_secret) -and -not [string]::IsNullOrWhiteSpace($cfg.agent_id) -and -not [string]::IsNullOrWhiteSpace($cfg.wecom_userid)) {
    Push-WeComApp $cfg.corp_id $cfg.corp_secret $cfg.agent_id $cfg.wecom_userid $content
    $pushed = $true
}

if (-not $pushed) { Write-Output "No push channel configured" }
