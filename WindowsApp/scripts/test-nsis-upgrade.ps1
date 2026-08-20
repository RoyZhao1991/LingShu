param(
  [Parameter(Mandatory = $true)]
  [string]$NewInstaller,

  [Parameter(Mandatory = $true)]
  [string]$ExpectedVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$PSNativeCommandUseErrorActionPreference = $false

$legacyVersion = "0.1.0-25"
$legacyInstallerUrl = "https://github.com/RoyZhao1991/LingShu/releases/download/windows-v0.1.0-preview.25/Nous-Windows-x64-Setup.exe"
$legacyInstallerSha256 = "c72bd80de859db7ca8733b9ed722addeb14a848b46f18d3bb3bc44062f529991"
$uninstallRegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Nous"
$currentManufacturerPath = "HKCU:\Software\Roy Zhao\Nous"
$legacyManufacturerPath = "HKCU:\Software\royzhao\Nous"
$defaultInstallDirectory = Join-Path $env:LOCALAPPDATA "Nous"
$legacyInstallDirectory = Join-Path $env:LOCALAPPDATA "Nous Legacy Install With Spaces"
$applicationProcessName = "lingshu-windows"
$applicationExecutableName = "lingshu-windows.exe"

$resolvedNewInstaller = [System.IO.Path]::GetFullPath($NewInstaller)
if (-not (Test-Path -LiteralPath $resolvedNewInstaller -PathType Leaf)) {
  throw "The newly built NSIS installer does not exist: $resolvedNewInstaller"
}

$tempRoot = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
  [System.IO.Path]::GetTempPath()
} else {
  $env:RUNNER_TEMP
}
$testRoot = Join-Path $tempRoot "lingshu-nsis-upgrade-$([guid]::NewGuid().ToString('N'))"
$legacyInstaller = Join-Path $testRoot "Nous-preview.25-Setup.exe"
$sentinelDirectory = Join-Path $env:LOCALAPPDATA "LingShu\ci-upgrade-regression\$([guid]::NewGuid().ToString('N'))"
$sentinelPath = Join-Path $sentinelDirectory "preserve-me.txt"
$sentinelValue = "LingShu user data must survive upgrade and uninstall: $([guid]::NewGuid())"

function Invoke-CheckedProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [string[]]$ArgumentList = @(),

    [Parameter(Mandatory = $true)]
    [string]$Operation,

    [int]$TimeoutSeconds = 180
  )

  if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    throw "$Operation could not start because the executable is missing: $FilePath"
  }

  Write-Host "::group::$Operation"
  Write-Host "Executable: $FilePath"
  Write-Host "Arguments: $($ArgumentList -join ' ')"
  $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru
  try {
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      & taskkill.exe /PID $process.Id /T /F | Out-Host
      throw "$Operation timed out after $TimeoutSeconds seconds (PID $($process.Id))."
    }
    if ($process.ExitCode -ne 0) {
      throw "$Operation failed with exit code $($process.ExitCode)."
    }
    Write-Host "$Operation completed with exit code 0."
  } finally {
    $process.Dispose()
    Write-Host "::endgroup::"
  }
}

function Wait-ForCondition {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Condition,

    [Parameter(Mandatory = $true)]
    [string]$FailureMessage,

    [int]$TimeoutSeconds = 30
  )

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    if (& $Condition) {
      return
    }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $deadline)

  throw "$FailureMessage (waited $TimeoutSeconds seconds)."
}

function Stop-TestApplication {
  $running = @(Get-Process -Name $applicationProcessName -ErrorAction SilentlyContinue)
  foreach ($process in $running) {
    Write-Warning "Stopping unexpected $applicationProcessName process $($process.Id) during CI cleanup."
    & taskkill.exe /PID $process.Id /T /F | Out-Null
  }
}

function Get-UninstallerPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$UninstallString
  )

  $trimmed = $UninstallString.Trim()
  if ($trimmed -match '^"([^"]+)"') {
    return $Matches[1]
  }
  if ($trimmed -match '^([^\s]+)') {
    return $Matches[1]
  }
  throw "Could not parse UninstallString: $UninstallString"
}

function Get-NormalizedInstallLocation {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InstallLocation
  )

  $trimmed = $InstallLocation.Trim().Trim([char]34)
  if ([string]::IsNullOrWhiteSpace($trimmed)) {
    throw "The Nous uninstall entry contains an empty InstallLocation."
  }
  return [System.IO.Path]::GetFullPath($trimmed).TrimEnd([char]92)
}

function Assert-NoApplicationProcess {
  $running = @(Get-Process -Name $applicationProcessName -ErrorAction SilentlyContinue)
  if ($running.Count -gt 0) {
    $ids = $running.Id -join ", "
    throw "The silent installer unexpectedly launched $applicationProcessName (PID(s): $ids)."
  }
}

function Assert-InstalledState {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Publisher
  )

  Wait-ForCondition -Condition {
    Test-Path -LiteralPath $uninstallRegistryPath
  } -FailureMessage "Nous $Version did not create its uninstall registration"

  $entry = Get-ItemProperty -LiteralPath $uninstallRegistryPath
  if ([string]$entry.DisplayVersion -ne $Version) {
    throw "Expected installed DisplayVersion '$Version', found '$($entry.DisplayVersion)'."
  }
  if (-not [string]::IsNullOrWhiteSpace($Publisher) -and [string]$entry.Publisher -ne $Publisher) {
    throw "Expected installed Publisher '$Publisher', found '$($entry.Publisher)'."
  }

  $installLocation = Get-NormalizedInstallLocation -InstallLocation ([string]$entry.InstallLocation)
  $applicationPath = Join-Path $installLocation $applicationExecutableName
  if (-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)) {
    throw "DisplayVersion is '$Version', but the application executable is missing: $applicationPath"
  }
  $applicationSha256 = (Get-FileHash -LiteralPath $applicationPath -Algorithm SHA256).Hash.ToLowerInvariant()

  $uninstallerPath = Get-UninstallerPath -UninstallString ([string]$entry.UninstallString)
  $expectedUninstallerPath = Join-Path $installLocation "uninstall.exe"
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
      [System.IO.Path]::GetFullPath($uninstallerPath),
      [System.IO.Path]::GetFullPath($expectedUninstallerPath)
    )) {
    throw "UninstallString points to '$uninstallerPath', expected '$expectedUninstallerPath'."
  }
  if (-not (Test-Path -LiteralPath $uninstallerPath -PathType Leaf)) {
    throw "The registered uninstaller is missing: $uninstallerPath"
  }

  Assert-NoApplicationProcess
  Write-Host "Verified Nous $Version at '$installLocation' (Publisher='$($entry.Publisher)')."
  return [pscustomobject]@{
    InstallLocation = $installLocation
    ApplicationPath = $applicationPath
    ApplicationSha256 = $applicationSha256
    UninstallerPath = $uninstallerPath
  }
}

function Remove-TestInstallation {
  Stop-TestApplication

  $candidateUninstallers = @()
  $knownInstallDirectories = @($defaultInstallDirectory, $legacyInstallDirectory)
  if (Test-Path -LiteralPath $uninstallRegistryPath) {
    try {
      $registered = Get-ItemProperty -LiteralPath $uninstallRegistryPath
      if (-not [string]::IsNullOrWhiteSpace([string]$registered.InstallLocation)) {
        $knownInstallDirectories += Get-NormalizedInstallLocation -InstallLocation ([string]$registered.InstallLocation)
      }
      if (-not [string]::IsNullOrWhiteSpace([string]$registered.UninstallString)) {
        $candidateUninstallers += Get-UninstallerPath -UninstallString ([string]$registered.UninstallString)
      }
    } catch {
      Write-Warning "Could not resolve the registered test uninstaller during cleanup: $($_.Exception.Message)"
    }
  }
  $candidateUninstallers += Join-Path $defaultInstallDirectory "uninstall.exe"

  foreach ($uninstaller in @($candidateUninstallers | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
      try {
        Invoke-CheckedProcess -FilePath $uninstaller -ArgumentList @("/S") -Operation "Cleanup silent uninstall" -TimeoutSeconds 120
      } catch {
        Write-Warning $_.Exception.Message
      }
      break
    }
  }

  Wait-ForCondition -Condition {
    $remainingExecutables = @(
      $knownInstallDirectories |
        Select-Object -Unique |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ $applicationExecutableName) }
    )
    $remainingExecutables.Count -eq 0 -and -not (Test-Path -LiteralPath $uninstallRegistryPath)
  } -FailureMessage "The test application executable or uninstall registration remained after cleanup" -TimeoutSeconds 20

  foreach ($installDirectory in @($knownInstallDirectories | Select-Object -Unique)) {
    Remove-Item -LiteralPath $installDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $uninstallRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $currentManufacturerPath -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $legacyManufacturerPath -Recurse -Force -ErrorAction SilentlyContinue
}

$completed = $false
try {
  New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
  Remove-TestInstallation

  Write-Host "Downloading the immutable preview.25 NSIS baseline from $legacyInstallerUrl"
  & curl.exe --fail --location --silent --show-error --retry 3 --retry-delay 2 --retry-all-errors --output $legacyInstaller $legacyInstallerUrl
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $legacyInstaller -PathType Leaf)) {
    throw "Failed to download preview.25 NSIS installer from '$legacyInstallerUrl' (curl exit code $LASTEXITCODE)."
  }
  $downloadedSha256 = (Get-FileHash -LiteralPath $legacyInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($downloadedSha256 -ne $legacyInstallerSha256) {
    throw "preview.25 installer checksum mismatch: expected '$legacyInstallerSha256', downloaded '$downloadedSha256'."
  }
  Write-Host "Verified preview.25 installer SHA-256: $downloadedSha256"

  # NSIS requires /D= to be the final raw option. The deliberately spaced path
  # locks down the legacy `_?=` migration contract instead of testing only the
  # default `%LOCALAPPDATA%\Nous` location.
  Invoke-CheckedProcess -FilePath $legacyInstaller -ArgumentList @("/S", "/NS", "/D=$legacyInstallDirectory") -Operation "Install preview.25 baseline into a spaced custom directory"
  $legacyState = Assert-InstalledState -Version $legacyVersion
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($legacyState.InstallLocation, $legacyInstallDirectory)) {
    throw "preview.25 ignored the custom install directory: expected '$legacyInstallDirectory', found '$($legacyState.InstallLocation)'."
  }
  if (-not (Test-Path -LiteralPath $legacyManufacturerPath)) {
    throw "preview.25 did not create its legacy manufacturer registry path '$legacyManufacturerPath'; the regression fixture is invalid."
  }

  New-Item -ItemType Directory -Force -Path $sentinelDirectory | Out-Null
  [System.IO.File]::WriteAllText($sentinelPath, $sentinelValue, [System.Text.UTF8Encoding]::new($false))
  Write-Host "Created user-data preservation sentinel: $sentinelPath"

  # Passive mode executes PageReinstall/PageLeaveReinstall. The explicit clean
  # upgrade switch selects the same verified old-uninstaller branch as the
  # interactive maintenance page, while /NS prevents an application launch.
  Invoke-CheckedProcess -FilePath $resolvedNewInstaller -ArgumentList @("/P", "/NS", "/UNINSTALLPREVIOUS") -Operation "Upgrade preview.25 through the verified legacy uninstall branch"
  $upgradedState = Assert-InstalledState -Version $ExpectedVersion -Publisher "Roy Zhao"
  if ($upgradedState.ApplicationSha256 -eq $legacyState.ApplicationSha256) {
    throw "Upgrade registration changed to '$ExpectedVersion', but the installed application binary still matches preview.25."
  }
  if (-not (Test-Path -LiteralPath $sentinelPath) -or (Get-Content -LiteralPath $sentinelPath -Raw) -ne $sentinelValue) {
    throw "LingShu user-data sentinel was changed or deleted during preview.25 upgrade: $sentinelPath"
  }

  Invoke-CheckedProcess -FilePath $resolvedNewInstaller -ArgumentList @("/S", "/NS") -Operation "Reinstall the same newly built version"
  $reinstalledState = Assert-InstalledState -Version $ExpectedVersion -Publisher "Roy Zhao"
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($upgradedState.InstallLocation, $reinstalledState.InstallLocation)) {
    throw "Same-version reinstall moved the application from '$($upgradedState.InstallLocation)' to '$($reinstalledState.InstallLocation)'."
  }
  if ($upgradedState.ApplicationSha256 -ne $reinstalledState.ApplicationSha256) {
    throw "Same-version reinstall produced an unexpected application binary hash change."
  }
  if (-not (Test-Path -LiteralPath $sentinelPath) -or (Get-Content -LiteralPath $sentinelPath -Raw) -ne $sentinelValue) {
    throw "LingShu user-data sentinel was changed or deleted during same-version reinstall: $sentinelPath"
  }

  Invoke-CheckedProcess -FilePath $reinstalledState.UninstallerPath -ArgumentList @("/S") -Operation "Uninstall the newly built version"
  Wait-ForCondition -Condition {
    (-not (Test-Path -LiteralPath $reinstalledState.ApplicationPath)) -and
      (-not (Test-Path -LiteralPath $uninstallRegistryPath))
  } -FailureMessage "Silent uninstall left the application executable or uninstall registration behind"
  Assert-NoApplicationProcess
  if (-not (Test-Path -LiteralPath $sentinelPath) -or (Get-Content -LiteralPath $sentinelPath -Raw) -ne $sentinelValue) {
    throw "LingShu user-data sentinel was changed or deleted by uninstall: $sentinelPath"
  }

  $completed = $true
  Write-Host "NSIS regression passed: preview.25 upgrade, same-version reinstall, silent uninstall, no GUI launch, and user-data preservation."
} finally {
  try {
    Remove-TestInstallation
  } catch {
    Write-Warning "Final NSIS test cleanup failed: $($_.Exception.Message)"
    if ($completed) {
      throw
    }
  } finally {
    Remove-Item -LiteralPath $sentinelDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
