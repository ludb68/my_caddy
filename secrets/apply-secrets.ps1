#requires -Version 5.1
<#
.SYNOPSIS
    把凭据（Docker Hub / GitHub）写进 GitHub 仓库的 Actions Secrets / Variables。

.DESCRIPTION
    凭据来源按优先级合并（先命中的值胜出）：
      1. ~/.pi/agent/skills/github/secrets.env      ← 推荐：随 skills 目录同步（D:\Sync\.agents\skills\github）
      2. ~/.pi/agent/skills/dockerhub/secrets.env   ← 推荐：随 skills 目录同步
      3. <repo>/secrets/gh-secrets.env              （项目内副本，兼容保留）
      4. ~/.pi/secrets/dockerhub.env  /  ~/.pi/secrets/github.env（旧位置，兼容保留）
    有 gh CLI 且已登录 → 直接写；没有 → 打印手动粘贴清单（-Copy <KEY> 可把值放剪贴板，-Open 打开设置页）
    任何情况下都只打印脱敏预览（前 4 位…后 4 位 + 长度）

.EXAMPLE
    pwsh -File secrets/apply-secrets.ps1
    pwsh -File secrets/apply-secrets.ps1 -Copy DOCKERHUB_TOKEN
    pwsh -File secrets/apply-secrets.ps1 -Open
#>
param(
    [string]$Copy,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

$candidateFiles = [ordered]@{
    'skill:github'    = Join-Path $env:USERPROFILE '.pi\agent\skills\github\secrets.env'
    'skill:dockerhub' = Join-Path $env:USERPROFILE '.pi\agent\skills\dockerhub\secrets.env'
    'repo:secrets'    = (Join-Path $PSScriptRoot 'gh-secrets.env')
    'home:dockerhub'  = Join-Path $env:USERPROFILE '.pi\secrets\dockerhub.env'
    'home:github'     = Join-Path $env:USERPROFILE '.pi\secrets\github.env'
}

$KEYS = @('DOCKERHUB_USERNAME', 'DOCKERHUB_TOKEN', 'DOCKERHUB_REPO',
          'GITHUB_REPO', 'GH_TOKEN', 'EXPECT_MODULES', 'VERIFY_MODULES')
$REQUIRED = @('DOCKERHUB_USERNAME', 'DOCKERHUB_TOKEN', 'DOCKERHUB_REPO')
$OPTIONAL = @('GITHUB_REPO', 'GH_TOKEN', 'EXPECT_MODULES', 'VERIFY_MODULES')

function Read-EnvFile([string]$path) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $map }
    foreach ($line in (Get-Content -LiteralPath $path)) {
        if ($line -match '^\s*#' -or $line.Trim().Length -eq 0) { continue }
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim().Trim('"').Trim("'")
            if ($val) { $map[$key] = $val }
        }
    }
    return $map
}

function Mask([string]$v) {
    if ([string]::IsNullOrEmpty($v)) { return '<空>' }
    if ($v.Length -le 8) { return ('*' * $v.Length) + "  ($($v.Length) 字符)" }
    return ($v.Substring(0, 4) + '…' + $v.Substring($v.Length - 4) + "  ($($v.Length) 字符)")
}

# ---- 合并各来源（先命中的胜出）----
$cfg = @{}
$origin = @{}
foreach ($name in $candidateFiles.Keys) {
    $path = $candidateFiles[$name]
    $data = Read-EnvFile $path
    foreach ($k in $data.Keys) {
        if ($KEYS -contains $k -and -not $cfg.ContainsKey($k)) {
            $cfg[$k] = $data[$k]
            $origin[$k] = $name
        }
    }
}

function Get-RepoSlug {
    if ($cfg['GITHUB_REPO']) { return $cfg['GITHUB_REPO'] }
    try {
        $url = (git -C $repoRoot remote get-url origin 2>$null)
        if ($url -match 'github\.com[:/](?<slug>[^/]+/[^/]+?)(\.git)?$') { return $Matches['slug'] }
    } catch { }
    return ''
}

$repo = Get-RepoSlug

# ---- -Copy 模式 ----
if ($Copy) {
    if (-not $cfg.ContainsKey($Copy)) { Write-Host "所有来源里都没有 $Copy" -ForegroundColor Red; exit 1 }
    Set-Clipboard -Value $cfg[$Copy]
    Write-Host "已复制 $Copy 到剪贴板（$(Mask $cfg[$Copy])，来源 $($origin[$Copy])）" -ForegroundColor Green
    exit 0
}

if ($Open) {
    if (-not $repo) { Write-Host "不知道仓库名，先把 GITHUB_REPO=owner/name 填上" -ForegroundColor Red; exit 1 }
    Start-Process "https://github.com/$repo/settings/secrets/actions"
    exit 0
}

# ---- 体检 ----
Write-Host "==== 凭据来源 ====" -ForegroundColor Cyan
foreach ($name in $candidateFiles.Keys) {
    $path = $candidateFiles[$name]
    $exists = if (Test-Path -LiteralPath $path) { '存在' } else { '无' }
    $hits = @($origin.Keys | Where-Object { $origin[$_] -eq $name })
    Write-Host ("  {0,-16} {1,-4} {2} {3}" -f $name, $exists, $path, $(if ($hits) { "← 提供 " + ($hits -join ',') } else { '' }))
}

Write-Host "`n==== 取值情况 ====" -ForegroundColor Cyan
foreach ($k in $KEYS) {
    $tag = if ($REQUIRED -contains $k) { '[必需]' } else { '[可选]' }
    $src = if ($origin.ContainsKey($k)) { "(来自 $($origin[$k]))" } else { '' }
    Write-Host ("  {0,-20} {1} {2} {3}" -f $k, $tag, (Mask $cfg[$k]), $src)
}

$missingRequired = @($REQUIRED | Where-Object { -not $cfg.ContainsKey($_) })
if ($missingRequired.Count -gt 0) {
    Write-Host "`n还缺（必需）：$($missingRequired -join ', ')" -ForegroundColor Yellow
    Write-Host '生产位置：' -ForegroundColor Yellow
    Write-Host '  DOCKERHUB_USERNAME / DOCKERHUB_TOKEN → https://hub.docker.com/settings/security（Generate new access token，Read & Write）' -ForegroundColor Yellow
    Write-Host '  DOCKERHUB_REPO                       → https://hub.docker.com/repository/create（形如 yourid/caddy，全小写）' -ForegroundColor Yellow
    Write-Host '填到（推荐，随 skills 目录同步）：' -ForegroundColor Yellow
    Write-Host "  $($candidateFiles['skill:dockerhub'])" -ForegroundColor Yellow
}
else {
    Write-Host "`n必需项已齐 ✔" -ForegroundColor Green
}
$missingOptional = @($OPTIONAL | Where-Object { -not $cfg.ContainsKey($_) })
if ($missingOptional.Count -gt 0) {
    Write-Host "未填（可选，不影响跑通）：$($missingOptional -join ', ')" -ForegroundColor DarkGray
}

# ---- 写 GitHub ----
Write-Host "`n==== 写入 GitHub ====" -ForegroundColor Cyan
if (-not $repo) {
    Write-Host "仓库 slug 未知：把 GITHUB_REPO=owner/name 填进 skill 目录的 secrets.env（或给 git 加 origin remote）后重跑" -ForegroundColor Yellow
    exit 0
}
Write-Host "目标仓库：$repo"

$secretsMap = [ordered]@{ 'DOCKERHUB_USERNAME' = $cfg['DOCKERHUB_USERNAME']; 'DOCKERHUB_TOKEN' = $cfg['DOCKERHUB_TOKEN'] }
$varsMap = [ordered]@{ 'DOCKERHUB_REPO' = $cfg['DOCKERHUB_REPO']; 'EXPECT_MODULES' = $cfg['EXPECT_MODULES']; 'VERIFY_MODULES' = $cfg['VERIFY_MODULES'] }

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Write-Host "未安装 gh CLI → 走手动路径（推荐，Secrets 写进去就读不出来了）" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1) 打开 https://github.com/$repo/settings/secrets/actions"
    Write-Host "  2) New repository secret（值可用 -Copy 复制，例如：pwsh -File secrets/apply-secrets.ps1 -Copy DOCKERHUB_TOKEN）"
    Write-Host "       DOCKERHUB_USERNAME = $($cfg['DOCKERHUB_USERNAME'])"
    Write-Host "       DOCKERHUB_TOKEN    = $(Mask $cfg['DOCKERHUB_TOKEN'])"
    Write-Host "  3) 切到 Variables 标签 → New repository variable："
    Write-Host "       DOCKERHUB_REPO  = $($cfg['DOCKERHUB_REPO'])"
    if ($cfg['EXPECT_MODULES']) { Write-Host "       EXPECT_MODULES  = $($cfg['EXPECT_MODULES'])" }
    if ($cfg['VERIFY_MODULES']) { Write-Host "       VERIFY_MODULES  = $($cfg['VERIFY_MODULES'])" }
    Write-Host "  4) 想以后自动写：scoop install gh ; gh auth login（需 repo/workflow 权限）"
    exit 0
}

$auth = (gh auth status 2>&1 | Out-String)
if ($auth -notmatch 'Logged in') {
    Write-Host "gh 未登录：先跑 gh auth login（浏览器授权，需要 repo/workflow 权限）" -ForegroundColor Yellow
    exit 1
}

foreach ($k in $secretsMap.Keys) {
    if (-not $secretsMap[$k]) { Write-Host "跳过 $k（空）" -ForegroundColor DarkGray; continue }
    $secretsMap[$k] | gh secret set $k --repo $repo
    if ($LASTEXITCODE -eq 0) { Write-Host "secret 已写入: $k" -ForegroundColor Green } else { Write-Host "写入失败: $k" -ForegroundColor Red }
}
foreach ($k in $varsMap.Keys) {
    if (-not $varsMap[$k]) { Write-Host "跳过 $k（空）" -ForegroundColor DarkGray; continue }
    gh variable set $k --repo $repo --body "$($varsMap[$k])"
    if ($LASTEXITCODE -eq 0) { Write-Host "variable 已写入: $k" -ForegroundColor Green } else { Write-Host "写入失败: $k" -ForegroundColor Red }
}

Write-Host "`n完成。接下来：git push → Actions 里跑 build-caddy 工作流" -ForegroundColor Green
