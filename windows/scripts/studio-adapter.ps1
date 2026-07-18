[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('preflight','install','apply','status','pause','resume','restore','verify','uninstall')]
  [string]$Operation,
  [switch]$RestartAuthorized,
  [switch]$ForceAuthorized,
  [switch]$DeleteUserThemes,
  [switch]$Deep
)

$ErrorActionPreference = 'Stop'

function Write-InvalidRequest {
  [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  $state = [pscustomobject][ordered]@{
    install = 'not-installed'
    codex = 'not-installed'
    session = 'official'
    operation = 'idle'
    themeName = $null
    requiresRestart = $false
    availableActions = @()
    verified = $null
  }
  $error = [pscustomobject][ordered]@{
    code = 'INVALID_REQUEST'
    message = 'The Studio operation is invalid.'
    recoveryActions = @('cancel')
  }
  $envelope = [pscustomobject][ordered]@{
    schemaVersion = 1
    ok = $false
    operation = $Operation
    state = $state
    error = $error
  }
  [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Compress -Depth 8))
  exit 2
}

if ($DeleteUserThemes -and $Operation -ne 'uninstall') { Write-InvalidRequest }
if ($ForceAuthorized -and -not $RestartAuthorized) { Write-InvalidRequest }
if ($Operation -notin @('preflight', 'status')) { Write-InvalidRequest }
if ($RestartAuthorized -or $ForceAuthorized -or $DeleteUserThemes) { Write-InvalidRequest }

& (Join-Path $PSScriptRoot 'status-dream-skin.ps1') -Operation $Operation -Deep:$Deep
exit $LASTEXITCODE
