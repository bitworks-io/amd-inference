# Loaded into FastLlm.psm1. Optional API key building blocks: generation, a per-user protected store, and the rule that decides whether a
# running server really enforces its key. Nothing here is called from a start, a setting or a window yet.
#
# The key is a secret. It is never placed in an argument list, a status document, a run log, a support bundle, a console line or an
# exception message. Failures here are typed and carry fixed text only: no error from the protector, the file system or a parser is
# forwarded, because such text can echo the value it was given.
#
# Key:   'fl-' + base64url(32 random bytes), 46 characters, with no comma, space or '#' (llama-server splits keys on commas).
# Store: <InstallRoot>\api-key.dat holds only bytes protected for the current user (Windows DPAPI, CurrentUser scope, fixed entropy).
$script:FastLlmApiKeyPattern = '^fl-[A-Za-z0-9_-]{43}$'
$script:FastLlmApiKeyFileName = 'api-key.dat'
$script:FastLlmApiKeyEntropyText = 'FastLLM.ApiKey.v1'
$script:FastLlmApiKeyIdPrefix = 'fastllm-api-key-id-v1:'
# The seam. $null means the real per-user protector. A test may set a hashtable of two script blocks: Protect and Unprotect, each taking
# and returning a byte array.
$script:FastLlmApiKeyProtector = $null

function New-FastLlmApiKeyFailure {
    param([Parameter(Mandatory = $true)][string] $Code, [Parameter(Mandatory = $true)][string] $Message)
    $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList ($Code + ': ' + $Message)
    $exception.Data['FastLlmFailureCode'] = $Code
    return $exception
}

function Test-FastLlmApiKeyFormat {
    param([AllowNull()] $Key)
    return [bool] (($Key -is [string]) -and ([string] $Key) -cmatch $script:FastLlmApiKeyPattern)
}

function New-FastLlmApiKey {
    [CmdletBinding()]
    param()
    $bytes = New-Object 'byte[]' 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    $text = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return ('fl-' + $text)
}

# A short public identifier of a key: the first 8 hex characters of SHA-256 over a fixed prefix plus the key. It tells two keys apart
# and gives nothing away about a 256-bit random key.
function Get-FastLlmApiKeyId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Key)
    if (-not (Test-FastLlmApiKeyFormat -Key $Key)) { throw (New-FastLlmApiKeyFailure -Code 'api-key-invalid' -Message 'The value is not a FastLLM API key.') }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:FastLlmApiKeyIdPrefix + $Key)) } finally { $sha.Dispose() }
    return ((($hash | Select-Object -First 4) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Protect-FastLlmApiKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Key)
    if (-not (Test-FastLlmApiKeyFormat -Key $Key)) { throw (New-FastLlmApiKeyFailure -Code 'api-key-invalid' -Message 'The value is not a FastLLM API key.') }
    $plain = [Text.Encoding]::UTF8.GetBytes($Key)
    try {
        if ($null -ne $script:FastLlmApiKeyProtector) { $protected = & $script:FastLlmApiKeyProtector.Protect $plain }
        else {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $protected = [Security.Cryptography.ProtectedData]::Protect($plain, [Text.Encoding]::UTF8.GetBytes($script:FastLlmApiKeyEntropyText), [Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        $protected = [byte[]] $protected
    }
    catch { throw (New-FastLlmApiKeyFailure -Code 'api-key-unavailable' -Message 'The API key could not be protected for this user. Nothing was stored.') }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
    if ($protected.Length -eq 0) { throw (New-FastLlmApiKeyFailure -Code 'api-key-unavailable' -Message 'The API key could not be protected for this user. Nothing was stored.') }
    return , $protected
}

# Returns the key text, or throws api-key-unavailable with fixed text. A value that does not unprotect to a well-formed key is unavailable too.
function Unprotect-FastLlmApiKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)
    $unavailable = 'The stored API key is missing or cannot be read by this user (for example after a moved profile or a restored backup). Create a new key.'
    $plain = $null
    $text = $null
    try {
        if ($Bytes.Length -eq 0) { throw 'empty' }
        if ($null -ne $script:FastLlmApiKeyProtector) { $plain = & $script:FastLlmApiKeyProtector.Unprotect $Bytes; $plain = [byte[]] $plain }
        else {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $plain = [Security.Cryptography.ProtectedData]::Unprotect($Bytes, [Text.Encoding]::UTF8.GetBytes($script:FastLlmApiKeyEntropyText), [Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        $text = [Text.Encoding]::UTF8.GetString($plain)
    }
    catch { $text = $null }
    finally { if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) } }
    if (-not (Test-FastLlmApiKeyFormat -Key $text)) { throw (New-FastLlmApiKeyFailure -Code 'api-key-unavailable' -Message $unavailable) }
    return $text
}

function Get-FastLlmApiKeyStorePath {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    return (Join-Path ([IO.Path]::GetFullPath($InstallRoot)) $script:FastLlmApiKeyFileName)
}

# Writes the protected bytes only, atomically (a temporary file in the same folder, then a replace). The temporary file also holds
# protected bytes only.
function Write-FastLlmApiKeyStore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][string] $Key)
    $protected = Protect-FastLlmApiKey -Key $Key
    $path = Get-FastLlmApiKeyStorePath -InstallRoot $InstallRoot
    $folder = Split-Path -Parent $path
    $temporary = Join-Path $folder ([Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null }
        if (Test-Path -LiteralPath $path) {
            $existing = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'unsafe' }
        }
        [IO.File]::WriteAllBytes($temporary, $protected)
        Move-FastLlmFileReplacing -Source $temporary -Destination $path
    }
    catch { throw (New-FastLlmApiKeyFailure -Code 'api-key-unavailable' -Message 'The API key store could not be written. Nothing was changed.') }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
}

function Read-FastLlmApiKeyStore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $path = Get-FastLlmApiKeyStorePath -InstallRoot $InstallRoot
    $bytes = $null
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 16384) { throw 'unsafe' }
        $bytes = [IO.File]::ReadAllBytes($path)
    }
    catch { $bytes = $null }
    if ($null -eq $bytes) { throw (New-FastLlmApiKeyFailure -Code 'api-key-unavailable' -Message 'The stored API key is missing or cannot be read by this user (for example after a moved profile or a restored backup). Create a new key.') }
    return (Unprotect-FastLlmApiKey -Bytes $bytes)
}

# The proof rule. After the server is healthy, one request to a protected endpoint without the key must be refused (401) and one with the
# key must succeed (200). Anything else means the key is not enforced, and nothing may claim it is.
function Get-FastLlmApiKeyEnforcement {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $WithoutKeyStatus, [Parameter(Mandatory = $true)][int] $WithKeyStatus)
    if ($WithoutKeyStatus -eq 401 -and $WithKeyStatus -eq 200) { return 'enforced' }
    return 'api-key-not-enforced'
}
