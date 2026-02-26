variable "aws_region" {
  type        = string
  description = "AWS region to deploy resources into."
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the SonarQube host."
}

variable "installation_os" {
  type        = string
  description = "Operating system selector (e.g., windows, linux)."
  validation {
    condition     = contains(["windows", "linux"], var.installation_os)
    error_message = "installation_os must be one of: windows, linux."
  }
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC ID. Leave empty to create a new VPC."
  default     = null
}

variable "vpc_name" {
  type        = string
  description = "Name tag for the VPC when one is created."
  default     = null
}

variable "vpn_cidr" {
  type        = string
  description = "CIDR block for the new VPC (only required when creating a VPC)."
  default     = null
}

variable "private_subnets" {
  type = list(string)
  description = <<EOT
Private subnet definitions. When creating a new VPC, supply CIDR blocks (matching availability_zones order).
When using an existing VPC, supply existing subnet IDs.
EOT
}

variable "public_subnets" {
  type = list(string)
  description = <<EOT
Public subnet definitions. When creating a new VPC, supply CIDR blocks (matching availability_zones order).
When using an existing VPC, supply existing public subnet IDs for the NLB.
EOT
  default = null
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones to span the private subnets (used when creating a new VPC)."
  default     = []
}

variable "hostname" {
  type        = string
  description = "Host label to use for DNS and EC2 Name tag."
}

variable "domain_name" {
  type        = string
  description = "Route53 hosted zone domain (e.g., example.com)."
}

variable "rds_name" {
  type        = string
  description = "Identifier/base name for the PostgreSQL instance and initial database."
}

variable "rds_instance_type" {
  type        = string
  description = "Instance class for the PostgreSQL database."
}

variable "rds_engine_version" {
  type        = string
  description = "PostgreSQL engine version for the RDS instance (e.g., 15.4)."
  default     = "15.4"
}

variable "db_username" {
  type        = string
  description = "Username for the PostgreSQL database."
  default     = "sonarqube"
}

variable "owner" {
  type        = string
  description = "Owner tag value for all resources."
}

variable "rdp_allowed_cidr" {
  type        = string
  description = "CIDR block allowed to access RDP port 3389 on the EC2 instance."
  default     = "0.0.0.0/0"
}

# options for installation
variable "install_chromium" {
  type        = bool
  description = "Whether to install Chromium."
  default     = true
}

variable "enable_rdp" {
  type        = bool
  description = "Whether to enable RDP access to the EC2 instance."
  default     = true
}

# Variables for SonarQube installation with user_data 
variable "zip_download_url" {
  type        = string
  description = "URL to download the SonarQube installer from."
  default     = "https://binaries.sonarsource.com/CommercialDistribution/sonarqube-enterprise/sonarqube-enterprise-2026.1.0.119033.zip"
}

variable "zip_filename" {
  type        = string
  description = "Name of the SonarQube installer file."
  default     = "SonarQube.zip"
}

variable "win_sonar_dir" {
  type        = string
  description = "Path where SonarQube will be downloaded and unzipped."
  default     = "c:\\SonarQube"
}

variable "linux_sonar_dir" {
  type        = string
  description = "Path where SonarQube will be downloaded and unzipped."
  default     = "/opt/"
}

variable "win_java_url" {
  type        = string
  description = "URL to download the Java installer from."
  default     = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.9%2B10/OpenJDK21U-jdk_x64_windows_hotspot_21.0.9_10.msi"
}

variable "win_java_filename" {
  type        = string
  description = "Name of the Java installer file."
  default     = "Java.msi"
}