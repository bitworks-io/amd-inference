# Loaded into FastLlm.psm1. Optional API key building blocks: generation, a per-user protected store, and the rule that decides whether a
# running server really enforces its key. Nothing here is called from a start, a setting or a window yet.
#
# The key is a secret. It is never placed in an argument list, a status document, a run log, a support bundle, a console line or an
# exception message. Failures here are typed and carry fixed text only: no error from the protector, the file system or a parser is
# forwarded, because such text can echo the value it was given.
#
# Key:   'fl-' + base64url(32 random bytes), 46 characters, with no comma, space or '#' (llama-server splits keys on commas).
# Store: <InstallRoot>\api-key.dat holds only bytes protected for the current user (Windows DPAPI, CurrentUser scope, fixed entropy).
# \A ... \z: the end-of-string anchor $ would also accept a trailing line feed.
$script:FastLlmApiKeyPattern = '\Afl-[A-Za-z0-9_-]{43}\z'
$script:FastLlmApiKeyLength = 46
$script:FastLlmApiKeyFileName = 'api-key.dat'
$script:FastLlmApiKeyEntropyText = 'FastLLM.ApiKey.v1'
$script:FastLlmApiKeyIdPrefix = 'fastllm-api-key-id-v1:'
# The seam. $null means the real per-user protector. A test may set a hashtable of two script blocks: Protect and Unprotect, each taking
# and returning a byte array.
$script:FastLlmApiKeyProtector = $null

# The key never crosses a function boundary as a plain [string] parameter: PowerShell module logging records bound parameter values
# verbatim. It travels in a [System.Security.SecureString] holder, whose logged form is only its type name, and is turned into text at the
# two use points only: the server child's environment and the bearer value handed to the loopback HTTP client. The holder parameters are
# left untyped on purpose: a typed binding error would echo the rejected value, so the check below throws a typed failure instead.

function New-FastLlmApiKeyFailure {
    param([Parameter(Mandatory = $true)][string] $Code, [Parameter(Mandatory = $true)][string] $Message)
    $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList ($Code + ': ' + $Message)
    $exception.Data['FastLlmFailureCode'] = $Code
    return $exception
}

# Returns a read-only SecureString holder for a well-formed key, or $null (never the text, never an error carrying it).
function ConvertTo-FastLlmApiKeyHolder {
    param([char[]] $Chars)
    if ($null -eq $Chars -or $Chars.Length -ne $script:FastLlmApiKeyLength) { return $null }
    if ((New-Object -TypeName System.String -ArgumentList (, $Chars)) -cnotmatch $script:FastLlmApiKeyPattern) { return $null }
    $holder = New-Object -TypeName System.Security.SecureString
    foreach ($c in $Chars) { $holder.AppendChar($c) }
    $holder.MakeReadOnly()
    return $holder
}

# The use point: the plain key text from a well-formed holder. Anything else (a plain string, $null, a malformed key) is api-key-invalid
# with fixed text.
function Get-FastLlmApiKeyText {
    param($ApiKeyHolder)
    $text = $null
    if ($ApiKeyHolder -is [System.Security.SecureString] -and $ApiKeyHolder.Length -eq $script:FastLlmApiKeyLength) {
        $pointer = [IntPtr]::Zero
        try {
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiKeyHolder)
            $text = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        }
        catch { $text = $null }
        finally { if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) } }
    }
    if ($null -eq $text -or $text -cnotmatch $script:FastLlmApiKeyPattern) { throw (New-FastLlmApiKeyFailure -Code 'api-key-invalid' -Message 'The API key is missing or malformed.') }
    return $text
}

# A new key in a holder: 'fl-' + base64url(32 random bytes), 46 characters, with no comma, space or '#' (llama-server splits keys on commas).
function New-FastLlmApiKey {
    [CmdletBinding()]
    param()
    $bytes = New-Object 'byte[]' 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    $chars = ('fl-' + [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')).ToCharArray()
    $holder = ConvertTo-FastLlmApiKeyHolder -Chars $chars
    [Array]::Clear($chars, 0, $chars.Length)
    [Array]::Clear($bytes, 0, $bytes.Length)
    return $holder
}

# A short public identifier of a key: the first 8 hex characters of SHA-256 over a fixed prefix plus the key. It tells two keys apart
# and gives nothing away about a 256-bit random key.
function Get-FastLlmApiKeyId {
    [CmdletBinding()]
    param($ApiKeyHolder)
    $text = Get-FastLlmApiKeyText -ApiKeyHolder $ApiKeyHolder
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:FastLlmApiKeyIdPrefix + $text)) } finally { $sha.Dispose() }
    return ((($hash | Select-Object -First 4) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Protect-FastLlmApiKey {
    [CmdletBinding()]
    param($ApiKeyHolder)
    $plain = [Text.Encoding]::UTF8.GetBytes((Get-FastLlmApiKeyText -ApiKeyHolder $ApiKeyHolder))
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

# Returns a holder, or throws api-key-unavailable with fixed text. A value that does not unprotect to a well-formed key is unavailable too.
function Unprotect-FastLlmApiKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)
    $unavailable = 'The stored API key is missing or cannot be read by this user (for example after a moved profile or a restored backup). Create a new key.'
    $plain = $null
    $chars = $null
    $holder = $null
    try {
        if ($Bytes.Length -eq 0) { throw 'empty' }
        if ($null -ne $script:FastLlmApiKeyProtector) { $plain = & $script:FastLlmApiKeyProtector.Unprotect $Bytes; $plain = [byte[]] $plain }
        else {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $plain = [Security.Cryptography.ProtectedData]::Unprotect($Bytes, [Text.Encoding]::UTF8.GetBytes($script:FastLlmApiKeyEntropyText), [Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        $chars = [Text.Encoding]::UTF8.GetChars($plain)
        $holder = ConvertTo-FastLlmApiKeyHolder -Chars $chars
    }
    catch { $holder = $null }
    finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
        if ($null -ne $chars) { [Array]::Clear($chars, 0, $chars.Length) }
    }
    if ($null -eq $holder) { throw (New-FastLlmApiKeyFailure -Code 'api-key-unavailable' -Message $unavailable) }
    return $holder
}

function Get-FastLlmApiKeyStorePath {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    return (Join-Path ([IO.Path]::GetFullPath($InstallRoot)) $script:FastLlmApiKeyFileName)
}

# Writes the protected bytes only, atomically (a temporary file in the same folder, then a replace). The temporary file also holds
# protected bytes only. A failed replace follows Move-FastLlmFileReplacing's contract: the original may already be gone and the temporary
# copy may be the only one, so it is kept and the message says so. Only a failure before the replace starts removes the temporary file
# and may say that nothing changed.
function Write-FastLlmApiKeyStore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot, $ApiKeyHolder)
    $protected = Protect-FastLlmApiKey -ApiKeyHolder $ApiKeyHolder
    $path = Get-FastLlmApiKeyStorePath -InstallRoot $InstallRoot
    $folder = Split-Path -Parent $path
    $temporary = Join-Path $folder ('api-key.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $stage = 'prepare'
    $failed = $false
    try {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null }
        if (Test-Path -LiteralPath $path) {
            $existing = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'unsafe' }
        }
        [IO.File]::WriteAllBytes($temporary, $protected)
        $stage = 'replace'
        Move-FastLlmFileReplacing -Source $temporary -Destination $path
    }
    catch { $failed = $true }
    if ($failed) {
        if ($stage -ceq 'prepare') {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
            throw (New-FastLlmApiKeyFailure -Code 'api-key-store-failed' -Message 'The API key store could not be written. Nothing was changed.')
        }
        throw (New-FastLlmApiKeyFailure -Code 'api-key-store-failed' -Message 'The API key store could not be updated. The previous key file may be unchanged or may be missing. A protected temporary copy of the new key was kept in the same folder. If the key cannot be read afterwards, create a new key.')
    }
    # Garbage from earlier failed replaces is collected after a successful write (older than ten minutes only).
    Remove-FastLlmStaleTemporaries -Folder $folder -NamePattern '^api-key\.[0-9a-f]{32}\.tmp$'
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
