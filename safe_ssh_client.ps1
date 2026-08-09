[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Name,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$Target,

    [Parameter(Position = 2)]
    [string]$Port = "22"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Fail([string]$Message) {
    throw $Message
}

function Assert-LastExitCode([string]$Operation) {
    if ($LASTEXITCODE -ne 0) {
        Fail "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Test-ExplicitHostAlias([string]$Text, [string]$Alias) {
    foreach ($Line in ($Text -split "`r?`n")) {
        if ($Line -match '^\s*Host\s+(?<patterns>[^#]+)') {
            foreach ($Pattern in ($Matches.patterns.Trim() -split '\s+')) {
                if ($Pattern -ieq $Alias) {
                    return $true
                }
            }
        }
    }
    return $false
}

function ConvertTo-SshConfigPath([string]$Path) {
    return '"' + ($Path -replace '\\', '/') + '"'
}

if ($Name -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$') {
    Fail "Name must start with a lowercase letter or digit and contain only lowercase letters, digits, dot, underscore, or hyphen (maximum 64 characters)."
}

if ($Target -notmatch '^(?<user>[A-Za-z_][A-Za-z0-9._-]*)@(?<host>[A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:]+\])$') {
    Fail "Target must be USER@HOST without shell syntax; bracket an IPv6 address."
}
$UserName = $Matches.user
$HostName = $Matches.host
if ($HostName.StartsWith('[')) {
    $HostName = $HostName.Substring(1, $HostName.Length - 2)
}

$PortNumber = 0
if ($Port -cnotmatch '^[0-9]+$' -or
    -not [int]::TryParse($Port, [ref]$PortNumber) -or
    $PortNumber -lt 1 -or $PortNumber -gt 65535) {
    Fail "Port must be an integer from 1 through 65535."
}
$Port = $PortNumber.ToString()

$SshKeygen = Get-Command "ssh-keygen.exe" -ErrorAction SilentlyContinue
if (-not $SshKeygen) {
    Fail "ssh-keygen.exe is missing. Install the Windows OpenSSH Client optional feature."
}
$Ssh = Get-Command "ssh.exe" -ErrorAction SilentlyContinue
if (-not $Ssh) {
    Fail "ssh.exe is missing. Install the Windows OpenSSH Client optional feature."
}

$SshDir = Join-Path $HOME ".ssh"
$SafeSshDir = Join-Path $SshDir "safe_ssh"
$ClientsDir = Join-Path $SafeSshDir "clients"
$ConfigSnippetsDir = Join-Path $SafeSshDir "config.d"
$ClientDir = Join-Path $ClientsDir $Name
$KeyFile = Join-Path $ClientDir "id_ed25519"
$PublicKeyFile = "$KeyFile.pub"
$KnownHostsFile = Join-Path $ClientDir "known_hosts"
$SnippetFile = Join-Path $ConfigSnippetsDir "$Name.conf"
$UserConfigFile = Join-Path $SshDir "config"

$ConfigIdentityFile = ConvertTo-SshConfigPath $KeyFile
$ConfigKnownHostsFile = ConvertTo-SshConfigPath $KnownHostsFile
$OwnedHeader = "# Managed by safe_ssh_client.ps1; do not edit."
$ManagedInclude = "Include ~/.ssh/safe_ssh/config.d/*.conf # safe_ssh managed include"
$ManagedReset = "Host * # safe_ssh managed scope reset"
$ExpectedSnippet = @"
$OwnedHeader
Host $Name
  HostName $HostName
  User $UserName
  Port $Port
  IdentityFile $ConfigIdentityFile
  IdentitiesOnly yes
  PreferredAuthentications publickey
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  UserKnownHostsFile $ConfigKnownHostsFile
  GlobalKnownHostsFile NUL
  StrictHostKeyChecking ask
  ControlMaster no
  ControlPath none
  ControlPersist no
"@
$ExistingConfig = ""
if (Test-Path -LiteralPath $UserConfigFile) {
    if (-not (Test-Path -LiteralPath $UserConfigFile -PathType Leaf)) {
        Fail "The current user's SSH config path is not a regular file: $UserConfigFile"
    }
    $ExistingConfig = [IO.File]::ReadAllText($UserConfigFile)
}

$ConfigLines = $ExistingConfig -split "`r?`n"
$HasManagedPreamble = ($ConfigLines.Count -ge 2 -and
    $ConfigLines[0] -ceq $ManagedInclude -and
    $ConfigLines[1] -ceq $ManagedReset)
$ManagedIncludeCount = @($ConfigLines | Where-Object { $_ -ceq $ManagedInclude }).Count
if ($HasManagedPreamble) {
    if ($ManagedIncludeCount -ne 1) {
        Fail "The SSH config has a duplicate or malformed safe_ssh managed Include."
    }
    $UnmanagedConfig = ($ConfigLines | Select-Object -Skip 2) -join "`n"
} else {
    if ($ManagedIncludeCount -ne 0 -or $ExistingConfig -match '(?im)^\s*Include\s+~/.ssh/safe_ssh/config\.d/\*') {
        Fail "The SSH config has an unmanaged or malformed safe_ssh Include."
    }
    $UnmanagedConfig = $ExistingConfig
}

if (Test-ExplicitHostAlias $UnmanagedConfig $Name) {
    Fail "Refusing to take over unmanaged Host alias '$Name' in $UserConfigFile."
}

if (Test-Path -LiteralPath $ConfigSnippetsDir -PathType Container) {
    foreach ($OtherSnippet in (Get-ChildItem -LiteralPath $ConfigSnippetsDir -File -Filter "*.conf")) {
        if ($OtherSnippet.FullName -ine $SnippetFile -and
            (Test-ExplicitHostAlias ([IO.File]::ReadAllText($OtherSnippet.FullName)) $Name)) {
            Fail "Refusing to take over unmanaged Host alias '$Name' in $($OtherSnippet.FullName)."
        }
    }
}

if (Test-Path -LiteralPath $SnippetFile) {
    if (-not (Test-Path -LiteralPath $SnippetFile -PathType Leaf)) {
        Fail "The managed alias snippet path is not a regular file: $SnippetFile"
    }
    $ExistingSnippet = [IO.File]::ReadAllText($SnippetFile)
    if ($ExistingSnippet -cne $ExpectedSnippet) {
        Fail "Refusing to replace an existing safe_ssh alias '$Name' with a different target, port, or configuration."
    }
}

$KeyExists = Test-Path -LiteralPath $KeyFile -PathType Leaf
$PublicKeyExists = Test-Path -LiteralPath $PublicKeyFile -PathType Leaf
if ($KeyExists -ne $PublicKeyExists) {
    Fail "The client key directory contains an incomplete key pair: $ClientDir"
}
if ((Test-Path -LiteralPath $KeyFile) -and -not $KeyExists) {
    Fail "The private-key path is not a regular file: $KeyFile"
}
if ((Test-Path -LiteralPath $PublicKeyFile) -and -not $PublicKeyExists) {
    Fail "The public-key path is not a regular file: $PublicKeyFile"
}

if (Test-Path -LiteralPath $KnownHostsFile) {
    if (-not (Test-Path -LiteralPath $KnownHostsFile -PathType Leaf)) {
        Fail "The alias known_hosts path is not a regular file: $KnownHostsFile"
    }
}

New-Item -ItemType Directory -Force -Path $ClientDir | Out-Null
New-Item -ItemType Directory -Force -Path $ConfigSnippetsDir | Out-Null

if (-not $KeyExists) {
    Write-Host "Generating a dedicated Ed25519 key. Press Enter twice for an empty passphrase."
    & $SshKeygen.Source -q -t ed25519 -C "safe_ssh:$Name" -f $KeyFile
    Assert-LastExitCode "ssh-keygen"
}

$PublicKey = (Get-Content -LiteralPath $PublicKeyFile -Raw).Trim()
if ($PublicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,3}(?: .*)?$') {
    Fail "The public key is not a valid Ed25519 public-key line: $PublicKeyFile"
}

Write-Host "Fingerprint:"
& $SshKeygen.Source -lf $PublicKeyFile
Assert-LastExitCode "public-key fingerprint calculation"

if (-not (Test-Path -LiteralPath $KnownHostsFile)) {
    [IO.File]::WriteAllText($KnownHostsFile, "")
}

if (-not (Test-Path -LiteralPath $SnippetFile)) {
    [IO.File]::WriteAllText($SnippetFile, $ExpectedSnippet)
}

if (-not $HasManagedPreamble) {
    $Preamble = "$ManagedInclude`r`n$ManagedReset`r`n"
    if ($ExistingConfig.Length -gt 0) {
        $Preamble += $ExistingConfig
    }
    [IO.File]::WriteAllText($UserConfigFile, $Preamble)
}

Write-Host "Private key: $KeyFile"
Write-Host "Public key: $PublicKeyFile"
Write-Host "Public-key line:"
Write-Host $PublicKey
Write-Host ""
Write-Host "Append the complete public-key line above to the intended Linux login user's ~/.ssh/authorized_keys file without overwriting existing keys."
Write-Host "After installing the key, connect with: ssh $Name"
Write-Host "On the first connection, verify the server host-key fingerprint before accepting it."
