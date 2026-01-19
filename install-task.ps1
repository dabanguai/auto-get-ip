$ErrorActionPreference = "Stop"

# 如果未显式传入任务名，使用默认名称
if (-not $TaskName) { $TaskName = "SendIPToWeCom" }

# 目标脚本路径：当前目录下的 send-ip.ps1
$scriptPath = Join-Path $PSScriptRoot "send-ip.ps1"
if (-not (Test-Path $scriptPath)) {
    exit 1
}

# 计划任务执行的 PowerShell 命令行参数
$arg = "-NoProfile -ExecutionPolicy Bypass -File \"" + $scriptPath + "\""

# 定义执行动作：调用 powershell.exe 运行 send-ip.ps1
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg

# 触发器1：当前用户登录时触发
$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:UserName

# 触发器2：工作站解锁时触发（Session Unlock）
$stateChangeTriggerClass = Get-CimClass -Namespace ROOT\Microsoft\Windows\TaskScheduler -ClassName MSFT_TaskSessionStateChangeTrigger
$unlock = New-CimInstance -CimClass $stateChangeTriggerClass -Property @{ StateChange = 8 } -ClientOnly

# 以当前交互用户身份运行任务
$principal = New-ScheduledTaskPrincipal -UserId $env:UserName -LogonType Interactive

# 任务设置：电池状态下也允许运行，不因电源变化停止
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# 已存在同名任务时先删除
try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
} catch {}

# 创建任务对象并注册到计划任务中
$task = New-ScheduledTask -Action $action -Trigger @($logon, $unlock) -Settings $settings -Principal $principal
Register-ScheduledTask -InputObject $task -TaskName $TaskName -Description "登录与解锁时推送IP到企微/PushPlus等" -RunLevel Highest | Out-Null

Write-Output "已安装任务：$TaskName"