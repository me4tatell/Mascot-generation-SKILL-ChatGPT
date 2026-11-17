<#
.SYNOPSIS
Copies a generated image to a new V1, V2, ... file without overwriting.
.EXAMPLE
& 'SKILL_DIR/scripts/save-result.ps1' -SourcePath 'C:\output\generated.png' -DestinationDirectory 'D:\project\outputs' -Stem 'ivan-football-red' -PromptPath 'C:\output\actual-prompt.txt'
.NOTES
Use absolute input/output paths and a semantic Stem without a version suffix.
PromptPath is optional; its exact bytes are copied into _work/prompts.
The source is never moved, changed, or deleted. Emits one JSON result.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$Stem,
    [string]$PromptPath
)

$ErrorActionPreference = 'Stop'
if ($Stem -match '-v\d+$') {
    throw 'Stem must not include a version suffix; the script chooses it.'
}
foreach ($taskPath in @($SourcePath, $DestinationDirectory)) {
    if (-not [System.IO.Path]::IsPathRooted($taskPath)) {
        throw 'SourcePath and DestinationDirectory must be absolute paths.'
    }
}
$source = (Get-Item -LiteralPath $SourcePath -ErrorAction Stop).FullName
if (-not [System.IO.File]::Exists($source)) { throw 'SourcePath must be a file.' }
$extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
if ($extension -notin @('.png', '.jpg', '.jpeg', '.webp')) {
    throw 'Source must be a PNG, JPEG, or WebP image; no conversion is performed.'
}

$promptSource = $null
if ($PromptPath) {
    if (-not [System.IO.Path]::IsPathRooted($PromptPath)) {
        throw 'PromptPath must be an absolute path.'
    }
    $promptSource = (Get-Item -LiteralPath $PromptPath -ErrorAction Stop).FullName
    if (-not [System.IO.File]::Exists($promptSource)) { throw 'PromptPath must be a file.' }
}

$destination = [System.IO.Path]::GetFullPath($DestinationDirectory)
[System.IO.Directory]::CreateDirectory($destination) | Out-Null
$promptDirectory = Join-Path $destination '_work\prompts'
if ($promptSource) { [System.IO.Directory]::CreateDirectory($promptDirectory) | Out-Null }

# Serialize the version choice for one destination/stem, even across file formats.
$hasher = [System.Security.Cryptography.SHA256]::Create()
try {
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($destination.ToUpperInvariant() + '|' + $Stem.ToLowerInvariant())
    $mutexKey = [System.BitConverter]::ToString($hasher.ComputeHash($keyBytes)).Replace('-', '')
} finally { $hasher.Dispose() }
$versionMutex = New-Object System.Threading.Mutex($false, ('Local\IvanMascotSave_' + $mutexKey))
$mutexOwned = $false
try {
    try { $mutexOwned = $versionMutex.WaitOne(30000) }
    catch [System.Threading.AbandonedMutexException] { $mutexOwned = $true }
    if (-not $mutexOwned) { throw 'Another save is still active for this image; retry shortly.' }

    # Consider every extension and saved prompt: an older version number is never reused.
    $versionPattern = '^' + [regex]::Escape($Stem) + '-V(?<number>[1-9][0-9]*)\.'
    $maxVersion = 0
    foreach ($scanDirectory in @($destination, $promptDirectory)) {
        if ([System.IO.Directory]::Exists($scanDirectory)) {
            foreach ($entry in Get-ChildItem -LiteralPath $scanDirectory -File) {
                if ($entry.Name -match $versionPattern) {
                    $maxVersion = [Math]::Max($maxVersion, [int]$Matches['number'])
                }
            }
        }
    }

    $version = $maxVersion + 1
    while ($true) {
        $baseName = $Stem + '-V' + $version
        $imagePath = Join-Path $destination ($baseName + $extension)
        $promptDestination = Join-Path $promptDirectory ($baseName + '.txt')
        if ([System.IO.File]::Exists($imagePath) -or [System.IO.File]::Exists($promptDestination)) {
            $version++
            continue
        }
        try {
            # File.Copy(..., false) also protects against writers outside this script.
            [System.IO.File]::Copy($source, $imagePath, $false)
            break
        }
        catch [System.IO.IOException] {
            if ([System.IO.File]::Exists($imagePath)) {
                $version++
                continue
            }
            throw
        }
    }

    $savedPrompt = $null
    if ($promptSource) {
        try {
            [System.IO.File]::Copy($promptSource, $promptDestination, $false)
            $savedPrompt = $promptDestination
        }
        catch {
            throw ('Image preserved at ' + $imagePath + '; prompt copy failed: ' + $_.Exception.Message)
        }
    }

    [ordered]@{
        image = $imagePath
        version = $version
        prompt = $savedPrompt
        sourcePreserved = $true
    } | ConvertTo-Json -Compress
}
finally {
    if ($mutexOwned) { $versionMutex.ReleaseMutex() }
    $versionMutex.Dispose()
}
