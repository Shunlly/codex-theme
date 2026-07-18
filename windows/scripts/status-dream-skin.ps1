[CmdletBinding()]
param(
  [ValidateSet('preflight', 'status')]
  [string]$Operation = 'status',
  [switch]$Deep
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'studio-windows.ps1')
[Console]::Error.WriteLine('DREAM_SKIN_PROGRESS checking')

$operationLock = $null
try {
  try {
    $operationLock = Enter-DreamSkinOperationLock
  } catch {
    $state = New-DreamSkinStudioState -Install 'not-installed' -Codex 'not-installed' -Session 'official' `
      -Operation 'busy' -ThemeName $null -Verified $null -AvailableActions @()
    $error = [pscustomobject][ordered]@{
      code = 'OPERATION_BUSY'
      message = 'Another Studio operation is already running.'
      recoveryActions = @('retry', 'cancel')
    }
    Write-DreamSkinStudioEnvelope -Operation $Operation -Ok $false -State $state -Error $error
    exit 1
  }
  Exit-DreamSkinOperationLock -Mutex $operationLock
  $operationLock = $null

  $status = Get-DreamSkinStudioStatus -Deep:$Deep
  Write-DreamSkinStudioEnvelope -Operation $Operation -Ok $status.Ok -State $status.State -Error $status.Error
  if ($status.Ok) { exit 0 }
  exit 1
} catch {
  $state = New-DreamSkinStudioState -Install 'not-installed' -Codex 'not-installed' -Session 'stale' `
    -ThemeName $null -Verified $null -AvailableActions @()
  $error = [pscustomobject][ordered]@{
    code = 'INTERNAL_ERROR'
    message = 'Studio status could not be read safely.'
    recoveryActions = @('retry', 'diagnostics', 'cancel')
  }
  Write-DreamSkinStudioEnvelope -Operation $Operation -Ok $false -State $state -Error $error
  exit 1
} finally {
  if ($null -ne $operationLock) { Exit-DreamSkinOperationLock -Mutex $operationLock }
}
