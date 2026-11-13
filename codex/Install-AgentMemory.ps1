[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VaultPath,
    [string]$SkillRoot = (Join-Path $env:USERPROFILE '.agents/skills'),
    [string]$CodexDirectory = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
)
$ErrorActionPreference = 'Stop'
# .NET file APIs resolve a relative path against the process directory, not $PWD: make both absolute first.
$SkillRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SkillRoot)
$CodexDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CodexDirectory)
$vault = (Resolve-Path -LiteralPath $VaultPath).Path
$memory = Join-Path $vault '5 Agent Memory'
if (-not (Test-Path -LiteralPath $memory -PathType Container)) { throw 'Existing 5 Agent Memory folder not found.' }
$destination = Join-Path $SkillRoot 'agent-memory'
if (Test-Path -LiteralPath $destination) { throw "Skill already exists: $destination. Review and update it manually." }
$instructions = Join-Path $CodexDirectory 'AGENTS.md'
$override = Join-Path $CodexDirectory 'AGENTS.override.md'
if ((Test-Path -LiteralPath $override) -and [IO.File]::ReadAllText($override).Trim()) { $instructions = $override }
$existing = if (Test-Path -LiteralPath $instructions) { [IO.File]::ReadAllText($instructions) } else { '' }
if ($existing.Contains('<!-- agent-memory:codex:start -->')) { throw 'Memory instructions already installed; review manually.' }
$block = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'global-agents-memory.md'))
New-Item -ItemType Directory -Path $SkillRoot -Force | Out-Null
New-Item -ItemType Directory -Path $CodexDirectory -Force | Out-Null
# From here a failure is undone, so a re-run is not refused by a half-installed skill or instructions block.
try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'agent-memory') -Destination $destination -Recurse
    $local = "# Local memory storage`n`nVault root: $vault`nMemory root: $memory`n`nUse this existing vault for all projects. Keep project notes scoped by their stable slug.`n"
    [IO.File]::WriteAllText((Join-Path $destination 'local-config.md'), $local)
    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'agent-memory/SKILL.md')).Hash
    $installedHash = (Get-FileHash -LiteralPath (Join-Path $destination 'SKILL.md')).Hash
    if ($sourceHash -ne $installedHash) { throw 'Installed skill verification failed.' }
    if ($existing) { Copy-Item -LiteralPath $instructions -Destination "$instructions.agent-memory-backup-$([guid]::NewGuid().ToString('N'))" }
    [IO.File]::WriteAllText($instructions, ($existing.TrimEnd() + "`n`n" + $block).TrimStart())
} catch {
    Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
    # The instructions write is the last step: if it half-happened, put back what was there.
    if ($existing) { try { [IO.File]::WriteAllText($instructions, $existing) } catch { } }
    throw
}
Write-Output "Installed skill: $destination"
Write-Output "Global instructions: $instructions"
Write-Output "Memory root verified: $memory"
