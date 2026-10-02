[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Z0-9]{10}$')][string]$TeamId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Z0-9]{10}$')][string]$KeyId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')][string]$IssuerId,
    [Parameter(Mandatory)][string]$PrivateKeyPath,
    [string]$BundleId = 'com.rio10255254.TaipeiBus',
    [string]$FeedbackEmail = '',
    [string]$PrivacyPolicyUrl = '',
    [string]$Repository = 'rio10255254/TaipeiBus'
)
$ErrorActionPreference = 'Stop'
if ($BundleId -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' -or $BundleId -like 'com.example.*') {
    throw '請使用實際註冊的 Bundle ID。'
}
if ($FeedbackEmail -and $FeedbackEmail -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { throw '回饋信箱格式不正確。' }
if ($PrivacyPolicyUrl -and $PrivacyPolicyUrl -notmatch '^https://') { throw '隱私政策需要 HTTPS 公開網址。' }
$keyFile = (Resolve-Path -LiteralPath $PrivateKeyPath).Path
$keyContents = [IO.File]::ReadAllText($keyFile).TrimStart([char]0xFEFF).Trim()
if ($keyContents -notmatch '(?s)^-----BEGIN PRIVATE KEY-----\s+[A-Za-z0-9+/=\r\n]+\s+-----END PRIVATE KEY-----$') {
    throw '請選擇 Apple 下載的完整 .p8 私鑰；私鑰不會印出或寫入專案。'
}
gh repo view $Repository --json nameWithOwner --jq '.nameWithOwner' | Out-Null
if ($LASTEXITCODE -ne 0) { throw '請先執行 gh auth login，確認可管理此私人儲存庫。' }
try {
    $settings = [ordered]@{ APPLE_TEAM_ID = $TeamId; ASC_KEY_ID = $KeyId; ASC_ISSUER_ID = $IssuerId; ASC_PRIVATE_KEY = $keyContents }
    foreach ($entry in $settings.GetEnumerator()) {
        # Pipe secret values through stdin; do not put the private key in shell arguments or logs.
        $entry.Value | gh secret set $entry.Key --repo $Repository
        if ($LASTEXITCODE -ne 0) { throw "無法設定 $($entry.Key)。已成功設定的值可安全重跑覆蓋。" }
        Write-Output "$($entry.Key) 已設定。"
    }
    $BundleId | gh variable set BUS_BUNDLE_ID --repo $Repository
    if ($LASTEXITCODE -ne 0) { throw '無法設定 Bundle ID。' }
    if ($FeedbackEmail) {
        $FeedbackEmail | gh variable set BUS_FEEDBACK_EMAIL --repo $Repository
        if ($LASTEXITCODE -ne 0) { throw '無法設定回饋信箱。' }
    }
    if ($PrivacyPolicyUrl) {
        $PrivacyPolicyUrl | gh variable set BUS_PRIVACY_POLICY_URL --repo $Repository
        if ($LASTEXITCODE -ne 0) { throw '無法設定隱私政策網址。' }
    }
} finally {
    $keyContents = $null
    if ($settings) { $settings.Clear() }
}
Write-Output '設定完成。下一步執行 TestFlight workflow 的 check-only。原始 .p8 檔仍由你自行保存。'
