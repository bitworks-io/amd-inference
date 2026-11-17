# Loaded into FastLlm.psm1. The optional API key: generation, a per-user protected store, the rule that decides whether a running server
# really enforces its key, the check that the key is sent only to FastLLM's own server, and the text scrub used wherever a failure is
# recorded or printed. The key is off unless the user turns it on (settings.json holds only apiKey: "on"; the key lives in the store).
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
# The second seam. $null means the real Windows listener table. A test may set a script block that takes a port and returns the ids of the
# processes that listen on 127.0.0.1 at that port.
$script:FastLlmApiKeyListenerOwners = $null
# A well-formed key inside other text. The edges keep a longer run of the same characters (a folder name, a hash) from matching.
$script:FastLlmApiKeyInTextPattern = '(?<![A-Za-z0-9_-])fl-[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])'

# The key never crosses a function boundary as a plain value - not as a [string], and not as a [char[]] or [byte[]] either: PowerShell
# module logging records bound parameter values verbatim, and it writes an array element by element. The key travels in a
# [System.Security.SecureString] holder, whose logged form is only its type name, and is turned into text at the two use points only: the
# server child's environment and the bearer value handed to the loopback HTTP client. Where characters or bytes must be handed on (the
# store read, the text scrub) they go inside a [ref], whose logged form is also only a type name. No cmdlet is ever given key text, as an
# argument or through the pipeline: a cmdlet's input is logged like any parameter. The holder parameters are left untyped on purpose: a
# typed binding error would echo the rejected value, so the check below throws a typed failure instead.

function New-FastLlmApiKeyFailure {
    param([Parameter(Mandatory = $true)][string] $Code, [Parameter(Mandatory = $true)][string] $Message)
    $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList ($Code + ': ' + $Message)
    $exception.Data['FastLlmFailureCode'] = $Code
    # A key failure is never retried, recovered with another model or replaced by the stand-in setup: none of those can fix it, and a
    # second start must not run without the key that was asked for.
    $exception.Data['FastLlmReason'] = 'ApiKeyFailed'
    return $exception
}

# Returns a read-only SecureString holder for a well-formed key, or $null (never the text, never an error carrying it). The characters
# arrive inside a [ref] (a [char[]] parameter would be logged character by character), and no cmdlet touches them: the string and the
# holder are made with constructors, not New-Object.
function ConvertTo-FastLlmApiKeyHolder {
    param([ref] $Chars)
    $characters = $null
    if ($null -ne $Chars) { $characters = $Chars.Value -as [char[]] }
    if ($null -eq $characters -or $characters.Length -ne $script:FastLlmApiKeyLength) { return $null }
    if ([string]::new($characters) -cnotmatch $script:FastLlmApiKeyPattern) { return $null }
    $holder = [System.Security.SecureString]::new()
    foreach ($c in $characters) { $holder.AppendChar($c) }
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
    $bytes = [byte[]]::new(32)
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    $chars = ('fl-' + [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')).ToCharArray()
    $holder = ConvertTo-FastLlmApiKeyHolder -Chars ([ref] $chars)
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
    # The first four bytes, as hex. No cmdlet is used: nothing derived from the key passes through a logged pipeline.
    return ([BitConverter]::ToString($hash, 0, 4).Replace('-', '').ToLowerInvariant())
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

# The protected store bytes, inside a [ref], to a holder; $null when they do not unprotect to a well-formed key. Never throws. The plain
# bytes and characters exist only inside this function and are cleared before it returns.
function ConvertFrom-FastLlmApiKeyProtected {
    param([ref] $Protected)
    $plain = $null
    $chars = $null
    $holder = $null
    try {
        $stored = $null
        if ($null -ne $Protected) { $stored = $Protected.Value -as [byte[]] }
        if ($null -eq $stored -or $stored.Length -eq 0) { throw 'empty' }
        if ($null -ne $script:FastLlmApiKeyProtector) { $plain = & $script:FastLlmApiKeyProtector.Unprotect $stored; $plain = [byte[]] $plain }
        else {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $plain = [Security.Cryptography.ProtectedData]::Unprotect($stored, [Text.Encoding]::UTF8.GetBytes($script:FastLlmApiKeyEntropyText), [Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        $chars = [Text.Encoding]::UTF8.GetChars($plain)
        $holder = ConvertTo-FastLlmApiKeyHolder -Chars ([ref] $chars)
    }
    catch { $holder = $null }
    finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
        if ($null -ne $chars) { [Array]::Clear($chars, 0, $chars.Length) }
    }
    return $holder
}

# Returns a holder, or throws api-key-unavailable with fixed text. A value that does not unprotect to a well-formed key is unavailable too.
# -Bytes is the PROTECTED form (what the store file holds), never the key. The start does not come this way: Read-FastLlmApiKeyStore
# hands the store bytes on inside a [ref], so even the protected form is not written to a module log.
function Unprotect-FastLlmApiKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)
    $holder = ConvertFrom-FastLlmApiKeyProtected -Protected ([ref] $Bytes)
    if ($null -eq $holder) { throw (New-FastLlmApiKeyFailure -Code 'api-key-unavailable' -Message 'The stored API key is missing or cannot be read by this user (for example after a moved profile or a restored backup). Create a new key.') }
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
    $holder = $null
    if ($null -ne $bytes) { $holder = ConvertFrom-FastLlmApiKeyProtected -Protected ([ref] $bytes) }
    if ($null -eq $holder) { throw (New-FastLlmApiKeyFailure -Code 'api-key-unavailable' -Message 'The stored API key is missing or cannot be read by this user (for example after a moved profile or a restored backup). Create a new key.') }
    return $holder
}

# The proof rule. After the server is healthy, one request to a protected endpoint without the key must be refused (401) and one with the
# key must succeed (200). Anything else means the key is not enforced, and nothing may claim it is.
function Get-FastLlmApiKeyEnforcement {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $WithoutKeyStatus, [Parameter(Mandatory = $true)][int] $WithKeyStatus)
    if ($WithoutKeyStatus -eq 401 -and $WithKeyStatus -eq 200) { return 'enforced' }
    return 'api-key-not-enforced'
}

# ---- wiring: what the entry points may ask of the store, the scrub, and the listener check ----

# What can be known about the store without the key: whether a store file exists, whether this user can read it, and the key's public id.
# Never throws and never returns the key.
function Get-FastLlmApiKeyStoreState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $exists = $false
    $available = $false
    $id = $null
    try { $exists = [bool] (Test-Path -LiteralPath (Get-FastLlmApiKeyStorePath -InstallRoot $InstallRoot)) } catch { $exists = $false }
    if ($exists) {
        try { $id = [string] (Get-FastLlmApiKeyId -ApiKeyHolder (Read-FastLlmApiKeyStore -InstallRoot $InstallRoot)); $available = $true }
        catch { $id = $null; $available = $false }
    }
    return [pscustomobject] [ordered] @{ exists = $exists; available = $available; apiKeyId = $id }
}

# Throws api-key-unavailable unless the stored key can be read now. For the checks that run before anything is started.
function Assert-FastLlmApiKeyStore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $null = Read-FastLlmApiKeyStore -InstallRoot $InstallRoot
}

# Writes a new key and reads it back. A key that cannot be read back was not created: api-key-store-failed.
function New-FastLlmApiKeyStoreEntry {
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $holder = New-FastLlmApiKey
    Write-FastLlmApiKeyStore -InstallRoot $InstallRoot -ApiKeyHolder $holder
    $state = Get-FastLlmApiKeyStoreState -InstallRoot $InstallRoot
    if (-not $state.available -or [string] $state.apiKeyId -cne [string] (Get-FastLlmApiKeyId -ApiKeyHolder $holder)) {
        throw (New-FastLlmApiKeyFailure -Code 'api-key-store-failed' -Message 'The new API key was written but could not be read back. Create a new key again.')
    }
    return [string] $state.apiKeyId
}

# Turning the key on: keeps a readable key, creates one only when there is no store file, and refuses (changing nothing) when a store file
# exists that this user cannot read. Replacing such a store is always the separate, explicit "create a new key" action.
function Initialize-FastLlmApiKeyStore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $state = Get-FastLlmApiKeyStoreState -InstallRoot $InstallRoot
    if ($state.available) { return [pscustomobject] [ordered] @{ created = $false; apiKeyId = [string] $state.apiKeyId } }
    if ($state.exists) {
        throw (New-FastLlmApiKeyFailure -Code 'api-key-unavailable' -Message 'The stored API key cannot be read by this user (for example after a moved profile or a restored backup). Nothing was changed. Create a new key.')
    }
    return [pscustomobject] [ordered] @{ created = $true; apiKeyId = (New-FastLlmApiKeyStoreEntry -InstallRoot $InstallRoot) }
}

# The explicit "create a new key" action (rotation, or recovery from an unreadable store): one atomic replace of the store. The key a
# running server was started with keeps working until that server stops; the new key applies at the next start.
function Reset-FastLlmApiKeyStore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $before = Get-FastLlmApiKeyStoreState -InstallRoot $InstallRoot
    return [pscustomobject] [ordered] @{ created = $true; apiKeyId = (New-FastLlmApiKeyStoreEntry -InstallRoot $InstallRoot); previousApiKeyId = $before.apiKeyId }
}

# The key as text, for the two places a person asks to see or copy it (settings -ApiKey show, and Show / Copy in Connect an app).
# The return value of a function is not recorded by module logging; the caller prints or copies it and keeps it nowhere.
function Get-FastLlmApiKeyForDisplay {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    return (Get-FastLlmApiKeyText -ApiKeyHolder (Read-FastLlmApiKeyStore -InstallRoot $InstallRoot))
}

# The scrub. Text that is recorded (status, run log, background record, support bundle) or printed (a failure line) passes through here:
# a well-formed key anywhere in it becomes <api-key>. In free text, whatever follows an api_key label is also removed to the end of its
# line (the server prints the last characters of the key there). -Structured is for serialized JSON: only the key itself is replaced, so
# the document keeps its shape. With the run's holder the exact key and its masked tail are removed as well.
# It never throws: a text it cannot work on is replaced whole (free text) or by an empty JSON object (-Structured).
# -Text is a [ref] to the text: what arrives here has not been scrubbed yet, and a [string] parameter would be written to a module log
# as it is. The referenced variable is not changed; the scrubbed text is the return value.
function ConvertTo-FastLlmKeyFreeText {
    [CmdletBinding()]
    param([ref] $Text, $ApiKeyHolder, [switch] $Structured)
    try {
        $source = $null
        if ($null -ne $Text) { $source = $Text.Value }
        if ($null -eq $source) { return '' }
        if ($source -isnot [string]) { throw 'not text' }
        if ($source.Length -eq 0) { return '' }
        $result = $source
        if ($null -ne $ApiKeyHolder) {
            $keyText = $null
            try { $keyText = Get-FastLlmApiKeyText -ApiKeyHolder $ApiKeyHolder } catch { $keyText = $null }
            if ($null -ne $keyText) {
                $result = $result.Replace($keyText, '<api-key>')
                $result = [regex]::Replace($result, ('\*{2,}' + [regex]::Escape($keyText.Substring($keyText.Length - 4))), '<api-key>')
            }
        }
        $result = [regex]::Replace($result, $script:FastLlmApiKeyInTextPattern, '<api-key>')
        if (-not $Structured) { $result = [regex]::Replace($result, '(?i)(api_keys?\b[ \t]*[:=]?)[^\r\n]*', '${1} <removed>') }
        return $result
    }
    catch {
        if ($Structured) { return '{}' }
        return '<text removed: it could not be checked for the API key>'
    }
}

# W4. The ids of the processes that listen on 127.0.0.1 at the port. Off Windows there is no listener table to ask (and no live start),
# so without the test seam this throws and the caller refuses.
function Get-FastLlmApiKeyListenerOwners {
    param([Parameter(Mandatory = $true)][int] $Port)
    if ($null -ne $script:FastLlmApiKeyListenerOwners) { return @(& $script:FastLlmApiKeyListenerOwners $Port) }
    if ($env:OS -ne 'Windows_NT') { throw 'The listener table is available on Windows only.' }
    if (-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WindowsGpuTelemetry.cs') -ErrorAction Stop }
    return @([Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners($Port))
}

# W4. Who listens on the port, compared with the server process this run recorded (process id and start time). One of:
#   verified  the recorded process is running and is the one and only owner of the 127.0.0.1 listener on the port
#   none      nothing listens on the port
#   other     something listens there that is not exactly the recorded process (another program, a second listener, a reused process id)
#   unknown   the check cannot be made (no recorded identity, not a loopback URL, a listener table that cannot be read)
# Never throws.
function Get-FastLlmApiKeyListenerVerdict {
    param([string] $BaseUrl, $ServerIdentity)
    try {
        $uri = [Uri] $BaseUrl
        $recordedPid = 0
        $recordedTicks = 0L
        $pidValue = $null
        $ticksValue = $null
        if ($ServerIdentity -is [System.Collections.IDictionary]) { $pidValue = $ServerIdentity['pid']; $ticksValue = $ServerIdentity['startUtcTicks'] }
        elseif ($null -ne $ServerIdentity) {
            if ($ServerIdentity.PSObject.Properties['pid']) { $pidValue = $ServerIdentity.pid }
            if ($ServerIdentity.PSObject.Properties['startUtcTicks']) { $ticksValue = $ServerIdentity.startUtcTicks }
        }
        if (-not ($uri.Scheme -ceq 'http' -and $uri.Host -ceq '127.0.0.1' -and $uri.Port -ge 1 -and $uri.Port -le 65535 -and
                [int]::TryParse([string] $pidValue, [ref] $recordedPid) -and $recordedPid -gt 0 -and
                [long]::TryParse([string] $ticksValue, [ref] $recordedTicks) -and $recordedTicks -gt 0)) { return 'unknown' }
        $owners = @(Get-FastLlmApiKeyListenerOwners -Port ([int] $uri.Port))
        if ($owners.Count -eq 0) { return 'none' }
        if ($owners.Count -ne 1 -or [int] $owners[0] -ne $recordedPid) { return 'other' }
        $alive = $false
        try {
            $process = [Diagnostics.Process]::GetProcessById($recordedPid)
            try { $alive = (-not $process.HasExited) -and ($process.StartTime.ToUniversalTime().Ticks -eq $recordedTicks) }
            finally { $process.Dispose() }
        }
        catch { $alive = $false }
        # The listener's process id is the recorded one, but the process is not the recorded one (it ended; the id was given out again).
        if (-not $alive) { return 'other' }
        return 'verified'
    }
    catch { return 'unknown' }
}

# W4. The key is sent only to FastLLM's own server. Before every request that carries it: the server process this run recorded (process id
# and start time) must still be running, and it must be the one and only owner of the 127.0.0.1 listener on the port. Anything else - a
# port taken over by another program after the server died, a second listener on the same port, a recorded process that is gone, a check
# that cannot be made - is api-key-listener-not-verified, and nothing is sent.
function Assert-FastLlmApiKeyListener {
    param([string] $BaseUrl, $ServerIdentity)
    if ((Get-FastLlmApiKeyListenerVerdict -BaseUrl $BaseUrl -ServerIdentity $ServerIdentity) -cne 'verified') {
        throw (New-FastLlmApiKeyFailure -Code 'api-key-listener-not-verified' -Message 'The program listening on the FastLLM port could not be confirmed to be the FastLLM server this run started, so the API key was not sent to it.')
    }
}

# W4, after the request. The check above and the request are two steps: a server that ends in between, with another program taking the
# port, would be sent the key. That cannot be prevented here, so it is detected: the same check runs again once the request is over.
#   -Answered (something answered the request): anything but 'verified' is a failure - whoever answered cannot be confirmed.
#   not answered (the request failed):           only 'other' is a failure. With nothing listening the key was sent to nobody (the usual
#                                                case: the server itself ended), and the request's own failure stands.
# The failure is api-key-listener-changed: the run stops, and the text says to create a new key, because this one may have been seen.
function Assert-FastLlmApiKeyListenerAfterSend {
    param([string] $BaseUrl, $ServerIdentity, [switch] $Answered)
    $verdict = Get-FastLlmApiKeyListenerVerdict -BaseUrl $BaseUrl -ServerIdentity $ServerIdentity
    if ($verdict -ceq 'verified') { return }
    if (-not $Answered -and $verdict -cne 'other') { return }
    throw (New-FastLlmApiKeyFailure -Code 'api-key-listener-changed' -Message 'Right after FastLLM sent a request with the API key, the program listening on the FastLLM port could no longer be confirmed to be the FastLLM server this run started. Another program may have received the key. FastLLM stopped. Create a new key (fast-llm.ps1 settings -ApiKey rotate, or Create a new key in Settings), give the new key to your apps, then start again.')
}
