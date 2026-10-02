[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Z0-9]{10}$')][string]$TeamId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Z0-9]{10}$')][string]$KeyId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')][string]$IssuerId,
    [Parameter(Mandatory)][string]$PrivateKeyPath,
    [ValidatePattern('^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$')][string]$BundleId = 'com.rio10255254.TaipeiBus',
    [string]$Repository = 'rio10255254/TaipeiBus',
    [string]$StatePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'work/apple-distribution-state.xml')
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This helper uses Windows user encryption to retain the signing key for safe retries.' }
$keyFile = (Resolve-Path -LiteralPath $PrivateKeyPath).Path
$StatePath = [IO.Path]::GetFullPath($StatePath)
$existingSecrets = (gh secret list --repo $Repository --json name | ConvertFrom-Json).name
if ($LASTEXITCODE -ne 0) { throw 'Cannot access GitHub repository secrets.' }
if (-not (Test-Path -LiteralPath $StatePath) -and ($existingSecrets -contains 'APPLE_DISTRIBUTION_P12')) {
    throw 'A distribution certificate is already configured. Recover its encrypted state instead of creating another certificate.'
}

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Security.Cryptography;
public static class BusDistributionApiSigner {
    public static string Sign(string path, string message) {
        using var key = ECDsa.Create();
        key.ImportFromPem(File.ReadAllText(path));
        var signature = key.SignData(Encoding.UTF8.GetBytes(message), HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        return Convert.ToBase64String(signature).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
}
"@
function ConvertTo-BusBase64Url([string]$Value) {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value)).TrimEnd('=').Replace('+','-').Replace('/','_')
}
function Invoke-BusAppleRequest([string]$Path, [string]$Method = 'GET', $Body = $null) {
    $uri = if ($Path.StartsWith('/v1/')) { [uri]("https://api.appstoreconnect.apple.com$Path") } else { [uri]$Path }
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'api.appstoreconnect.apple.com') { throw 'Unexpected Apple API host.' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = ConvertTo-BusBase64Url ((@{alg='ES256';kid=$KeyId;typ='JWT'} | ConvertTo-Json -Compress))
    $payload = ConvertTo-BusBase64Url ((@{iss=$IssuerId;iat=$now;exp=($now+600);aud='appstoreconnect-v1'} | ConvertTo-Json -Compress))
    $message = "$header.$payload"
    $token = "$message.$([BusDistributionApiSigner]::Sign($keyFile, $message))"
    try {
        $arguments = @{Uri=$uri;Method=$Method;Headers=@{Authorization="Bearer $token";Accept='application/json'};SkipHttpErrorCheck=$true;TimeoutSec=45}
        if ($null -ne $Body) { $arguments.ContentType='application/json'; $arguments.Body=($Body | ConvertTo-Json -Depth 15 -Compress) }
        $response = Invoke-WebRequest @arguments
        try { $data = $response.Content | ConvertFrom-Json } catch { throw "Apple returned HTTP $([int]$response.StatusCode) with an unreadable response." }
        if ([int]$response.StatusCode -ge 400) {
            $errors = @($data.errors | ForEach-Object { "$($_.code): $($_.title)" }) -join '; '
            throw "Apple HTTP $([int]$response.StatusCode): $errors"
        }
        return $data
    } finally { $token=$null; $message=$null }
}
function Get-BusAppleRows([string]$Path) {
    $rows = @()
    do {
        $response = Invoke-BusAppleRequest $Path
        $rows += @($response.data | Where-Object { $_ })
        $Path = $response.links.next
    } while ($Path)
    return $rows
}
function Save-BusSigningState {
    [IO.Directory]::CreateDirectory((Split-Path $StatePath -Parent)) | Out-Null
    # SecureString fields are protected by Windows DPAPI for the current user.
    $script:state | Export-Clixml -LiteralPath $StatePath -Depth 5
}
$rsa = [Security.Cryptography.RSA]::Create(2048)
$certificateWithKey = $null
try {
    if (Test-Path -LiteralPath $StatePath) {
        $script:state = Import-Clixml -LiteralPath $StatePath
        if ($state.TeamId -ne $TeamId -or $state.BundleId -ne $BundleId -or $state.Repository -ne $Repository) { throw 'Encrypted signing state belongs to another team, app or repository.' }
        $encodedKey = ConvertFrom-SecureString -SecureString $state.PrivateKey -AsPlainText
        $privateBytes = [Convert]::FromBase64String($encodedKey)
        $bytesRead = 0
        $rsa.ImportPkcs8PrivateKey($privateBytes, [ref]$bytesRead)
        [Array]::Clear($privateBytes, 0, $privateBytes.Length)
        $encodedKey = $null
    } else {
        $state = [pscustomobject]@{
            TeamId=$TeamId;BundleId=$BundleId;Repository=$Repository;CertificateId='';ProfileId=''
            PrivateKey=(ConvertTo-SecureString -String ([Convert]::ToBase64String($rsa.ExportPkcs8PrivateKey())) -AsPlainText -Force)
            Password=(ConvertTo-SecureString -String ([Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))) -AsPlainText -Force)
        }
        Save-BusSigningState
    }
    $publicKey = [Convert]::ToBase64String($rsa.ExportSubjectPublicKeyInfo())
    $certificates = @(Get-BusAppleRows '/v1/certificates?filter%5BcertificateType%5D=DISTRIBUTION&limit=200')
    $certificate = $null
    foreach ($row in $certificates) {
        if (-not $row.attributes.certificateContent) { continue }
        $publicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($row.attributes.certificateContent))
        $candidateKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($publicCertificate)
        try {
            if ($candidateKey -and [Convert]::ToBase64String($candidateKey.ExportSubjectPublicKeyInfo()) -eq $publicKey) { $certificate=$row; break }
        } finally { if ($candidateKey) { $candidateKey.Dispose() }; $publicCertificate.Dispose() }
    }
    if (-not $certificate) {
        if ($state.CertificateId) { throw 'The previously configured certificate is no longer available. Resolve that certificate before replacing signing materials.' }
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=TaipeiBus CI', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        # Retain the encrypted key before creating the certificate. A retry can find it by its public key.
        $result = Invoke-BusAppleRequest '/v1/certificates' 'POST' @{data=@{type='certificates';attributes=@{certificateType='DISTRIBUTION';csrContent=$request.CreateSigningRequestPem()}}}
        $certificate = $result.data
        $state.CertificateId = $certificate.id
        Save-BusSigningState
    }
    if ([DateTimeOffset]::Parse($certificate.attributes.expirationDate) -le [DateTimeOffset]::UtcNow.AddDays(7)) { throw 'Distribution certificate expires within seven days.' }
    $publicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($certificate.attributes.certificateContent))
    try {
        if ($publicCertificate.Subject -notmatch ('(?:^|,\s*)OU=' + [regex]::Escape($TeamId) + '(?:,|$)')) { throw 'Distribution certificate team mismatch.' }
        $certificateWithKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($publicCertificate, $rsa)
    } finally { $publicCertificate.Dispose() }
    $state.CertificateId = $certificate.id
    Save-BusSigningState

    $bundleRows = @(Get-BusAppleRows ("/v1/bundleIds?filter%5Bidentifier%5D=$([uri]::EscapeDataString($BundleId))&limit=10"))
    $bundle = $bundleRows | Where-Object { $_.attributes.identifier -eq $BundleId } | Select-Object -First 1
    if (-not $bundle) { throw 'App ID is not registered in this team.' }
    $profileName = "TaipeiBus TestFlight $($certificate.id)"
    $profiles = @(Get-BusAppleRows '/v1/profiles?filter%5BprofileType%5D=IOS_APP_STORE&limit=200')
    $profile = $profiles | Where-Object { $_.attributes.name -eq $profileName -and $_.attributes.profileState -eq 'ACTIVE' } | Select-Object -First 1
    if (-not $profile) {
        $result = Invoke-BusAppleRequest '/v1/profiles' 'POST' @{data=@{type='profiles';attributes=@{name=$profileName;profileType='IOS_APP_STORE'};relationships=@{bundleId=@{data=@{type='bundleIds';id=$bundle.id}};certificates=@{data=@(@{type='certificates';id=$certificate.id})}}}}
        $profile = $result.data
    }
    if ([DateTimeOffset]::Parse($profile.attributes.expirationDate) -le [DateTimeOffset]::UtcNow.AddDays(7)) { throw 'App Store profile expires within seven days.' }
    $state.ProfileId=$profile.id
    Save-BusSigningState
    $password = ConvertFrom-SecureString -SecureString $state.Password -AsPlainText
    $settings = [ordered]@{
        APPLE_DISTRIBUTION_P12=[Convert]::ToBase64String($certificateWithKey.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, $password))
        APPLE_DISTRIBUTION_PASSWORD=$password
        APPLE_APP_STORE_PROFILE=$profile.attributes.profileContent
    }
    foreach ($entry in $settings.GetEnumerator()) {
        $entry.Value | gh secret set $entry.Key --repo $Repository
        if ($LASTEXITCODE -ne 0) { throw "Could not set $($entry.Key). Rerun with the same encrypted state to recover." }
        Write-Output "$($entry.Key) configured."
    }
    [ordered]@{certificate_id=$certificate.id;profile_id=$profile.id;profile_uuid=$profile.attributes.uuid;expires=$profile.attributes.expirationDate;status='distribution_signing_configured'} | ConvertTo-Json -Compress
} finally {
    $password=$null
    if ($settings) { $settings.Clear() }
    if ($certificateWithKey) { $certificateWithKey.Dispose() }
    $rsa.Dispose()
}
