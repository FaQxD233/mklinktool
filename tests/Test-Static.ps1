# 静态检查：仓库中所有 .ps1 无语法错误且为 UTF-8 带 BOM，所有 .cmd 为纯 ASCII（见 AGENTS.md 的编码约定）。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$repoRoot = Split-Path -Parent $PSScriptRoot

$scripts = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' })
foreach ($file in $scripts) {
    $relative = $file.FullName.Substring($repoRoot.Length).TrimStart('\')
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $detail = (@($errors) | ForEach-Object { 'L{0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) -join '; '
    Assert ($errors.Count -eq 0) "$relative parses" $detail
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    Assert ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "$relative has UTF-8 BOM"
}

foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.cmd' -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' })) {
    $relative = $file.FullName.Substring($repoRoot.Length).TrimStart('\')
    $nonAscii = @([System.IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }).Count
    Assert ($nonAscii -eq 0) "$relative is pure ASCII" "non-ASCII bytes=$nonAscii"
}

Write-TestSummary
if ($script:TestFail -gt 0) { exit 1 }
exit 0
