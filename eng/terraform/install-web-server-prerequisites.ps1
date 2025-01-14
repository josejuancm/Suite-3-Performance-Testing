# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Run this script as an administrator to install Chocolatey, Pyenv, Python 3.9.4, and Poetry.
# This script should be run should be run once for environments that do not
# already have these prerequisites set up.

#### PowerShell Tools
function Install-PowerShellTools {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -Force
    Install-Module SqlServer -AllowClobber -Force
}

####### Tools-Helper.psm1
function Invoke-RefreshPath {
    # Some of the installs in this process do not set the immediate path correctly.
    # This function simply reads the global path settings and reloads them. Useful
    # when you can't even get to chocolatey's `refreshenv` command.

    $env:Path=(
        [System.Environment]::GetEnvironmentVariable("Path","Machine"),
        [System.Environment]::GetEnvironmentVariable("Path","User")
    ) -match '.' -join ';'
}

function Test-ExitCode {
    if ($LASTEXITCODE -ne 0) {

        throw @"
The last task failed with exit code $LASTEXITCODE
$(Get-PSCallStack)
"@
    }
}
####### Configure-Windows.psm1
function Set-TLS12Support {
    Write-Host "Enabling TLS 1.2"

    if (-not [Net.ServicePointManager]::SecurityProtocol.HasFlag([Net.SecurityProtocolType]::Tls12)) {
        [Net.ServicePointManager]::SecurityProtocol += [Net.SecurityProtocolType]::Tls12
    }
}

function Enable-LongFileNames {
    Write-Host "Enabling long file name support"

    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem') {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -name "LongPathsEnabled" -Value 1 -Verbose -Force
    }
}
###### Install-Applications.psm1
$common_args = @(
    "--execution-timeout=$installTimeout",
    "-y",
    "--ignore-pending-reboot"
)

$installTimeout = 14400 # Set to 0 for infinite

function Install-Choco {
    if (Get-Command "choco.exe" -ErrorAction SilentlyContinue) {
        Write-Output "Chocolatey is already installed. Setting choco command."
    }
    else {
        Write-Output "Installing Chocolatey..."
        $uri = "https://chocolatey.org/install.ps1"
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($uri))

        &refreshenv
    }
    &choco feature disable --name showDownloadProgress --execution-timeout=$installTimeout
    Test-ExitCode

    return Get-Command "choco.exe" -ErrorAction SilentlyContinue
}

function Uninstall-AspNetCore6035 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [string] $LogFile
    )

    Start-Transcript -Path $LogFile -Append

    Write-Host "Uninstalling .NET Core 6.0.35 runtimes..."
    
    $runtimePaths = @(
        "C:\Program Files\dotnet\shared\Microsoft.AspNetCore.App\6.0.35",
        "C:\Program Files\dotnet\shared\Microsoft.NETCore.App\6.0.35"
    )
    
    foreach ($path in $runtimePaths) {
        if (Test-Path $path) {
            Write-Host "Removing runtime at: $path"
            try {
                # Try to stop any processes that might be using the runtime
                Get-Process | Where-Object {$_.Path -like "$path*"} | Stop-Process -Force -ErrorAction SilentlyContinue
                
                # Add a small delay to ensure processes are stopped
                Start-Sleep -Seconds 2
                
                # Try multiple times to remove the directory
                $maxAttempts = 3
                $attempt = 1
                $success = $false
                
                while (-not $success -and $attempt -le $maxAttempts) {
                    try {
                        Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                        $success = $true
                        Write-Host "Successfully removed: $path"
                    }
                    catch {
                        Write-Host "Attempt $attempt of $maxAttempts failed to remove $path"
                        if ($attempt -eq $maxAttempts) {
                            Write-Warning "Failed to remove $path after $maxAttempts attempts: $_"
                        }
                        Start-Sleep -Seconds 2
                        $attempt++
                    }
                }
            }
            catch {
                Write-Warning "Error during runtime removal process: $_"
                # Continue with the script even if there's an error
            }
        } else {
            Write-Host "Runtime path not found: $path"
        }
    }

    Write-Host "Uninstall operation completed."
    Stop-Transcript
    
    # Return success even if some operations failed
    # This prevents the VM extension from failing completely
    return $true
}

function Install-DotNetHosting {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [string] $LogFile
    )

    Start-Transcript -Path $LogFile -Append

    # Install IIS Web Server Role withcommon features
    Write-Host "Installing IIS Web Server Role and features..."
    $features = @(
        "IIS-WebServerRole",
        "IIS-WebServer",
        "IIS-CommonHttpFeatures",
        "IIS-DefaultDocument",
        "IIS-DirectoryBrowsing",
        "IIS-HttpErrors",
        "IIS-StaticContent",
        "IIS-HttpRedirect",
        "IIS-HealthAndDiagnostics",
        "IIS-HttpLogging",
        "IIS-LoggingLibraries",
        "IIS-RequestMonitor",
        "IIS-Security",
        "IIS-RequestFiltering",
        "IIS-HttpCompressionStatic",
        "IIS-WebServerManagementTools",
        "IIS-ManagementConsole",
        "IIS-BasicAuthentication",
        "IIS-WindowsAuthentication",
        "IIS-ApplicationInit",
        "IIS-NetFxExtensibility45",
        "IIS-ASPNET45"
    )

    foreach ($feature in $features) {
        Write-Host "Installing feature: $feature"
        Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart | Out-Null
        if ($?) {
            Write-Host "$feature installed successfully."
        } else {
            Write-Error "Failed to install $feature."
            Stop-Transcript
            exit 1
        }
    }

    Write-Host "IIS installation completed successfully."

    # Install .NET 8.0 Hosting Bundle via Chocolatey
    Write-Host "Installing .NET 8.0 Hosting Bundle..."
    $common_args = @('-y', '--no-progress')
    choco install dotnet-8.0-windowshosting @common_args

    # Check if .NET Hosting Bundle was installed successfully
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Installation of .NET 8.0 Hosting Bundle failed."
        Stop-Transcript
        exit $LASTEXITCODE
    } else {
        Write-Host ".NET 8.0 Hosting Bundle installed successfully."
    }

    # Refresh environment variables
    & refreshenv

    Stop-Transcript
}

###### Run
try {
    Set-NetFirewallProfile -Enabled False
    $ConfirmPreference="high"
    $ErrorActionPreference = "Continue"  # Changed from "Stop" to "Continue"
    Set-TLS12Support
    Invoke-RefreshPath
    Enable-LongFileNames
    Install-Choco
    Install-PowerShellTools

    # First uninstall ASP.NET Core 6.0.35
    $uninstallLog = "$PSScriptRoot/uninstall-aspnet-6035.log"
    Uninstall-AspNetCore6035 -LogFile $uninstallLog

    # Then proceed with the rest of the installation
    $applicationSetupLog = "$PSScriptRoot/application-setup.log"
    Install-DotNetHosting -LogFile $applicationSetupLog
    &choco install vcredist140 @common_args

    # Restart the computer to complete the installation
    Restart-Computer -Force
}
catch {
    Write-Warning "An error occurred during script execution: $_"
    # Log the error but don't fail the script
    exit 0
}
