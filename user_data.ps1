<powershell>
# This script downloads and installs SonarQube Server on a Windows machine

Start-Transcript -Path "C:\Userdata.log"

# Variables
# The url to download SonarQube zip file from (passed from Terraform)
$url = "${url}"

# The url for java file
$javaUrl = "${java_url}"

# The zip file will be downloaded here:
$path = "${path}"

# The name of saved zip file
$zipFileName = "${zip_filename}"

# The name of saved java file
$javaFileName = "${java_filename}"

# The full path of the downloaded zip file
$outputFilePath = Join-Path -Path $path -ChildPath $zipFileName

# The full path of the downloaded java file
$javaOutputFilePath = Join-Path -Path $path -ChildPath $javaFileName

# Temporary path needed to identify the directory name extracted from zip
$tempExtractPath = Join-Path -Path $path -ChildPath "tmp_extract"

# Determine if Chromium should be installed
$installChromium = [System.Convert]::ToBoolean("${install_chromium}")

# Database connection URL
$jdbcUrl = "${jdbc_url}"

# Database username
$dbUsername = "${db_username}"

# Database password
$dbPassword = "${db_password}"

Write-Host "Checking for directory: $path"

# Check if the target directory exists
if (-not (Test-Path -Path $path)) {
    # If the directory does not exist, create it.
    Write-Host "Directory not found. Creating it..."
    try {
        New-Item -Path $path -ItemType Directory -ErrorAction Stop
        Write-Host "Successfully created directory: $path"
    } catch {
        Write-Host "An error occurred while trying to create the directory."
        Write-Host $_.Exception.Message
    }
} else {
    # If the directory already exists
    Write-Host "Directory already exists."
}

# Download and install Java
try {
  Write-Host "Starting Java installation"
  $webClient = New-Object System.Net.WebClient
  $webClient.DownloadFile($javaUrl, $javaOutputFilePath)
  Write-Host "Successfully downloaded file $javaOutputFilePath."
  Write-Host "Starting Java installation"
  $javaInstallProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$javaOutputFilePath`" INSTALLLEVEL=1 /quiet /norestart" -Wait -PassThru
  if ($javaInstallProcess.ExitCode -notin @(0, 3010)) {
    throw "Java installation failed. Exit code: $($javaInstallProcess.ExitCode)"
  }
  Write-Host "Successfully installed Java."
  
  # Wait a moment for Java installation to complete
  Start-Sleep -Seconds 5
  
  # Find Java installation path
  Write-Host "Locating Java installation..."
  $javaPaths = @(
    "C:\Program Files\Java\*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\*\bin\java.exe",
    "C:\Program Files\Eclipse Foundation\*\bin\java.exe",
    "C:\Program Files (x86)\Java\*\bin\java.exe"
  )
  
  $javaExePath = $null
  foreach ($pathPattern in $javaPaths) {
    $foundJava = Get-ChildItem -Path $pathPattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($foundJava) {
      $javaExePath = $foundJava.FullName
      Write-Host "Found Java at: $javaExePath"
      break
    }
  }
  
  if ($null -eq $javaExePath) {
    Write-Host "WARNING: Could not automatically find Java installation. Searching registry..."
    # Try to find Java via registry
    $javaRegistryPaths = @(
      "HKLM:\SOFTWARE\JavaSoft\Java Development Kit",
      "HKLM:\SOFTWARE\Eclipse Adoptium",
      "HKLM:\SOFTWARE\Eclipse Foundation"
    )
    
    foreach ($regPath in $javaRegistryPaths) {
      if (Test-Path $regPath) {
        $javaVersions = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
        foreach ($version in $javaVersions) {
          $javaHome = (Get-ItemProperty -Path $version.PSPath -Name "JavaHome" -ErrorAction SilentlyContinue).JavaHome
          if ($javaHome) {
            $testJavaExe = Join-Path -Path $javaHome -ChildPath "bin\java.exe"
            if (Test-Path $testJavaExe) {
              $javaExePath = $testJavaExe
              Write-Host "Found Java via registry at: $javaExePath"
              break
            }
          }
        }
        if ($javaExePath) { break }
      }
    }
  }
  
  if ($null -eq $javaExePath) {
    Write-Host "ERROR: Could not locate Java installation. Service installation may fail."
  } else {
    # Set environment variables for current session and system-wide
    $javaBinPath = Split-Path -Path $javaExePath -Parent
    $javaHomePath = Split-Path -Path $javaBinPath -Parent
    
    Write-Host "Setting Java environment variables:"
    Write-Host "  JAVA_HOME: $javaHomePath"
    Write-Host "  SONAR_JAVA_PATH: $javaExePath"
    
    # Set for current session
    $env:JAVA_HOME = $javaHomePath
    $env:SONAR_JAVA_PATH = $javaExePath
    $env:PATH = "$javaBinPath;$env:PATH"
    
    # Set system-wide 
    [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHomePath, [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable("SONAR_JAVA_PATH", $javaExePath, [System.EnvironmentVariableTarget]::Machine)
    
    # Update PATH system-wide
    $currentPath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine)
    if ($currentPath -notlike "*$javaBinPath*") {
      $newPath = "$javaBinPath;$currentPath"
      [System.Environment]::SetEnvironmentVariable("PATH", $newPath, [System.EnvironmentVariableTarget]::Machine)
      Write-Host "  Updated system PATH to include: $javaBinPath"
    }
    
    Write-Host "Java environment variables set successfully."
  }
} catch {
  Write-Host "Error occured during Java installation"
  Write-Host $_.Exception.Message
}

# Download SonarQube zip file
try {
    Write-Host "Starting SonarQube zipfile download"
    $webClient = New-Object System.Net.WebClient
    $webClient.DownloadFile($url, $outputFilePath)
    Write-Host "Successfully downloaded file $outputFilePath."
} catch {
  Write-Host "Error occured while downloading the file"
  Write-Host $_.Exception.Message
}

# We need to capture sonarHome. For this we extract into a temp directory, examine its content
# and then move it back to $path
try {
    # 1. Clean up previous temp folder if it exists
    if (Test-Path $tempExtractPath) { Remove-Item $tempExtractPath -Recurse -Force }

    # 2. Extract to the temp folder
    Expand-Archive -Path $outputFilePath -DestinationPath $tempExtractPath -Force

    # 3. Identify the extracted content
    $extractedItems = Get-ChildItem -Path $tempExtractPath

    # Variable to hold the final path
    $sonarHome = $null

    if ($extractedItems.Count -eq 1 -and $extractedItems.PSIsContainer) {
        # Zip contains a single root folder (standard for GitHub zips)
        $rootFolderName = $extractedItems[0].Name
        $sonarHome = Join-Path -Path $path -ChildPath $rootFolderName

        # Move the folder from temp to the main path
        # (Remove existing destination if necessary to allow overwrite)
        if (Test-Path $sonarHome) { Remove-Item $sonarHome -Recurse -Force }
        Move-Item -Path $extractedItems[0].FullName -Destination $path
    } else {
        # Zip contains multiple top level files/dirs
        # Create a folder based on the zip filename to contain them
        $folderName = [System.IO.Path]::GetFileNameWithoutExtension($zipFileName)
        $sonarHome = Join-Path -Path $path -ChildPath $folderName
        
        if (Test-Path $sonarHome) { Remove-Item $sonarHome -Recurse -Force }
        New-Item -Path $sonarHome -ItemType Directory | Out-Null
        
        # Move all loose items to this new specific folder
        Move-Item -Path "$tempExtractPath\*" -Destination $sonarHome
    }

    # 4. Cleanup Temp
    Remove-Item $tempExtractPath -Recurse -Force

    Write-Host "Successfully unzipped."
    Write-Host "sonarHome variable set to: $sonarHome"

} catch {
    Write-Host "An error occurred while unzipping or processing variables."
    Write-Host $_.Exception.Message
}

# inside the sonarHome/conf directory, edit the sonar.properties file to set the database connection URL, username and password
try {
    Write-Host "Editing sonar.properties file to set the database connection URL, username and password."
    $sonarPropertiesFile = Join-Path -Path $sonarHome -ChildPath "conf\sonar.properties"
    $sonarPropertiesContent = Get-Content -Path $sonarPropertiesFile -Raw
    
    # Create banner and configuration to append
    $banner = @"

################################################################################
# Configuration added by launch script
# This section was automatically generated during system initialization
################################################################################
"@
    
    $dbConfig = @"
sonar.jdbc.url=$jdbcUrl
sonar.jdbc.username=$dbUsername
sonar.jdbc.password=$dbPassword
"@
    
    # Append banner and configuration to the file
    $updatedContent = $sonarPropertiesContent + "`n" + $banner + "`n" + $dbConfig
    Set-Content -Path $sonarPropertiesFile -Value $updatedContent -NoNewline
    Write-Host "Successfully edited sonar.properties file."
} catch {
    Write-Host "An error occurred while editing the sonar.properties file."
    Write-Host $_.Exception.Message
}

${agentic_setup}

# Install and start SonarQube
if ($null -ne $sonarHome) {
    $serviceBatchFile = Join-Path -Path $sonarHome -ChildPath "bin\windows-x86-64\SonarService.bat"
    Write-Host "Checking for service file at: $serviceBatchFile"

    if (Test-Path $serviceBatchFile) {
        Write-Host "Found service file. Running install command..."
        try {
            # Refresh environment variables from registry to ensure Java paths are available
            Write-Host "Refreshing environment variables..."
            $env:JAVA_HOME = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", [System.EnvironmentVariableTarget]::Machine)
            $env:SONAR_JAVA_PATH = [System.Environment]::GetEnvironmentVariable("SONAR_JAVA_PATH", [System.EnvironmentVariableTarget]::Machine)
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine) + ";" + [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
            
            Write-Host "Current environment variables:"
            Write-Host "  JAVA_HOME: $env:JAVA_HOME"
            Write-Host "  SONAR_JAVA_PATH: $env:SONAR_JAVA_PATH"
            Write-Host "  PATH contains Java: $($env:PATH -like '*Java*' -or $env:PATH -like '*jdk*')"
            
            # Verify java.exe is accessible
            $javaCheck = Get-Command java.exe -ErrorAction SilentlyContinue
            if ($javaCheck) {
                Write-Host "  java.exe found at: $($javaCheck.Source)"
            } else {
                Write-Host "  WARNING: java.exe not found in PATH, but SONAR_JAVA_PATH is set to: $env:SONAR_JAVA_PATH"
            }
            
            # Install the service with environment variables explicitly set
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = $env:ComSpec
            $processInfo.Arguments = '/d /s /c ""{0}" install"' -f $serviceBatchFile
            $processInfo.UseShellExecute = $false
            $processInfo.RedirectStandardOutput = $true
            $processInfo.RedirectStandardError = $true
            $processInfo.CreateNoWindow = $true
            
            # Set environment variables for the process
            $processInfo.EnvironmentVariables["JAVA_HOME"] = $env:JAVA_HOME
            $processInfo.EnvironmentVariables["SONAR_JAVA_PATH"] = $env:SONAR_JAVA_PATH
            $processInfo.EnvironmentVariables["PATH"] = $env:PATH
            
            $installProcess = New-Object System.Diagnostics.Process
            $installProcess.StartInfo = $processInfo
            $installProcess.Start() | Out-Null
            $installOutput = $installProcess.StandardOutput.ReadToEnd()
            $installError = $installProcess.StandardError.ReadToEnd()
            $installProcess.WaitForExit()
            $installExitCode = $installProcess.ExitCode
            
            Write-Host "Service installation exit code: $installExitCode"
            if ($installOutput) {
                Write-Host "Installation output: $installOutput"
            }
            if ($installError) {
                Write-Host "Installation errors: $installError"
            }
            
            if ($installExitCode -ne 0) {
                Write-Host "Service installation failed. Exit code: $installExitCode"
                throw "Service installation failed. Exit code: $installExitCode"
            }
            
            Write-Host "Service installation command executed successfully."
            
            # Start the service
            Write-Host "Starting SonarQube service..."
            $startProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startProcessInfo.FileName = $env:ComSpec
            $startProcessInfo.Arguments = '/d /s /c ""{0}" start"' -f $serviceBatchFile
            $startProcessInfo.UseShellExecute = $false
            $startProcessInfo.RedirectStandardOutput = $true
            $startProcessInfo.RedirectStandardError = $true
            $startProcessInfo.CreateNoWindow = $true
            $startProcessInfo.EnvironmentVariables["JAVA_HOME"] = $env:JAVA_HOME
            $startProcessInfo.EnvironmentVariables["SONAR_JAVA_PATH"] = $env:SONAR_JAVA_PATH
            $startProcessInfo.EnvironmentVariables["PATH"] = $env:PATH
            
            $startProcess = New-Object System.Diagnostics.Process
            $startProcess.StartInfo = $startProcessInfo
            $startProcess.Start() | Out-Null
            $startOutput = $startProcess.StandardOutput.ReadToEnd()
            $startError = $startProcess.StandardError.ReadToEnd()
            $startProcess.WaitForExit()
            $startExitCode = $startProcess.ExitCode
            
            Write-Host "Service start exit code: $startExitCode"
            if ($startOutput) {
                Write-Host "Start output: $startOutput"
            }
            if ($startError) {
                Write-Host "Start errors: $startError"
            }
            
            if ($startExitCode -eq 0) {
                Write-Host "Service started successfully."
            } else {
                Write-Host "WARNING: Service start returned exit code: $startExitCode"
            }
        } catch {
            Write-Host "An error occurred while trying to run the installation batch file."
            Write-Host $_.Exception.Message
            Write-Host $_.Exception.StackTrace
        }
    } else {
        Write-Host "WARNING: Service batch file not found."
        Write-Host "If you downloaded the PowerShell source code instead of SonarQube, this is expected."
    }
} else {
    Write-Host "Skipping service installation because sonarHome path could not be determined."
}

# add firewall rule for SonarQube
try {
    Write-Host "Adding firewall rule for SonarQube."
    New-NetFirewallRule -DisplayName "NLB-Inbound-TCP-9000-SonarQube" -Direction Inbound -LocalPort 9000 -Protocol TCP -Action Allow -Profile Any
    Write-Host "Successfully added firewall rule for SonarQube."
} catch {
    Write-Host "Error occured while adding firewall rule for SonarQube."
    Write-Host $_.Exception.Message
}

# install chromium
if ($installChromium) {
  try {
    Write-Host "Starting Chromium installation."
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    choco install -y chromium
    Write-Host "Successfully installed Chromium."
    } catch {
        Write-Host "Error occured while installing Chromium."
        Write-Host $_.Exception.Message
    }
}

Write-Host "Script finished."

</powershell>