<powershell>
# This script downloads and installs SonarQube Server on a Windows machine

# Variables
# The url to download SonarQube zip file from
$url = "https://binaries.sonarsource.com/CommercialDistribution/sonarqube-enterprise/sonarqube-enterprise-2025.5.0.113872.zip"

$ The url for java file
$javaUrl = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.9%2B10/OpenJDK21U-jdk_x64_windows_hotspot_21.0.9_10.msi"

# The zip file will be downloaded here:
$path = "C:\SonarQube"

# The name of saved zip file
$zipFileName = "SonarQube.zip"

# The full path of the downloaded zip file
$outputFilePath = Join-Path -Path $path -ChildPath $zipFileName

# Temporary path needed to identify the directory name extracted from zip
$tempExtractPath = Join-Path -Path $path -ChildPath "tmp_extract"


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


# Install and start SonarQube
if ($null -ne $sonarHome) {
    $serviceBatchFile = Join-Path -Path $sonarHome -ChildPath "bin\windows-x86-64\SonarService.bat"
    Write-Host "Checking for service file at: $serviceBatchFile"

    if (Test-Path $serviceBatchFile) {
        Write-Host "Found service file. Running install command..."
        try {
            # execute the batch file with the "install" argument
            & $serviceBatchFile install
            Write-Host "Service installation command executed successfully."
        } catch {
            Write-Host "An error occurred while trying to run the installation batch file."
            Write-Host $_.Exception.Message
        }
    } else {
        Write-Host "WARNING: Service batch file not found."
        Write-Host "If you downloaded the PowerShell source code instead of SonarQube, this is expected."
    }
} else {
    Write-Host "Skipping service installation because sonarHome path could not be determined."
}
    


Write-Host "Script finished."

</powershell>