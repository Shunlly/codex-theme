[CmdletBinding()]
param(
  [int]$Port = 9335,
  [string]$NodePath,
  [switch]$AdapterLockHeld
)

$ErrorActionPreference = 'Stop'
$PortExplicit = $PSBoundParameters.ContainsKey('Port')
$Injector = Join-Path $PSScriptRoot 'injector.mjs'
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'theme-windows.ps1')

$operationLock = $null
if (-not (Test-DreamSkinAdapterOperationLockOwner -AdapterLockHeld:$AdapterLockHeld)) {
  $operationLock = Enter-DreamSkinOperationLock
}
try {
  $node = Get-DreamSkinNodeRuntime -NodePath $NodePath
  $StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  $StatePath = Join-Path $StateRoot 'state.json'
  $state = Read-DreamSkinState -Path $StatePath
  if ($null -eq $state) { throw 'STATE_UNSAFE: No saved Dream Skin session is available to pause.' }
  if (-not $PortExplicit) { $Port = [int]$state.port }
  Assert-DreamSkinPort -Port $Port
  if ([int]$state.port -ne $Port -or
    -not (Test-DreamSkinPathEqual -Left "$($state.nodePath)" -Right $node.Path) -or
    -not (Test-DreamSkinPathEqual -Left "$($state.injectorPath)" -Right $Injector) -or
    -not (Test-DreamSkinBrowserId -Value "$($state.browserId)")) {
    throw 'STATE_UNSAFE: The saved Dream Skin runtime identity is invalid.'
  }

  $registeredInstalls = @(Get-DreamSkinRegisteredCodexInstalls)
  $codex = Resolve-DreamSkinCodexInstallFromState -State $state -RegisteredInstalls $registeredInstalls
  if ($null -eq $codex -or (Get-DreamSkinCodexProcesses -Codex $codex).Count -eq 0) {
    throw 'STATE_UNSAFE: The saved Codex process identity is no longer active.'
  }
  $cdpIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $codex
  if ($null -eq $cdpIdentity -or $cdpIdentity.BrowserId -cne "$($state.browserId)") {
    throw 'STATE_UNSAFE: The active CDP browser does not match the saved Dream Skin session.'
  }
  $injectorProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$state.injectorPid)" `
    -ErrorAction SilentlyContinue
  if ($null -eq $injectorProcess) { throw 'STATE_UNSAFE: The saved injector process is no longer active.' }

  $null = Stop-DreamSkinRecordedInjector -State $state
  & $node.Path $Injector --remove --port $Port --browser-id $cdpIdentity.BrowserId --timeout-ms 8000
  if ($LASTEXITCODE -ne 0) { throw 'LIVE_REMOVE_FAILED: The live theme could not be removed safely.' }
  Set-DreamSkinPaused -Paused $true -StateRoot $StateRoot | Out-Null
  Write-Host 'Codex Dream Skin is paused.'
} finally {
  if ($null -ne $operationLock) { Exit-DreamSkinOperationLock -Mutex $operationLock }
}
