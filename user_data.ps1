<powershell>
# Define variables from Terraform
$url = "${source_url}"
$path = "${sonar_dir}"

# Create the destination directory if it doesn't exist
$directory = Split-Path -Path $path -Parent
if (-not (Test-Path -Path $directory)) {
  New-Item -ItemType Directory -Path $directory -Force
}

# Add logging to help with debugging
Add-Content -Path "C:\Temp\userdata-log.txt" -Value "Starting file download from $url at $(Get-Date)"

try {
  # Download the file
  Invoke-WebRequest -Uri $url -OutFile $path
  Add-Content -Path "C:\Temp\userdata-log.txt" -Value "Successfully downloaded file to $path"
}
catch {
  # Log any errors
  Add-Content -Path "C:\Temp\userdata-log.txt" -Value "Error downloading file: $_"
}

</powershell>