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

variable "install_chromium" {
  type        = bool
  description = "Whether to install Chromium."
}

variable "enable_rdp" {
  type        = bool
  description = "Whether to enable RDP access to the EC2 instance."
}

# Variables for SonarQube installation with user_data 
variable "zip_download_url" {
  type        = string
  description = "SonarQube distribution ZIP URL. The release in this URL selects the server version to install."
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

variable "deploy_agentic_containers" {
  type        = bool
  description = "Deploy the 2026.5 agentic pack and hosted MCP alongside the Linux ZIP installation."
  default     = false

  validation {
    condition = !var.deploy_agentic_containers || (
      var.installation_os == "linux" &&
      can(regex("(^|/)sonarqube-(enterprise|datacenter)-2026\\.5\\.[0-9]+\\.[0-9]+\\.zip([?#].*)?$", var.zip_download_url))
    )
    error_message = "Agentic containers require installation_os=linux and a 2026.5 distribution ZIP named sonarqube-<enterprise|datacenter>-2026.5.<patch>.<build>.zip. For other server versions, set deploy_agentic_containers=false."
  }
}

variable "agentic_generator_revision" {
  type        = string
  description = "Pinned 40-character commit of SonarSource/docker-sonarqube with 2026.5 agentic-compose-generator defaults."
  default     = ""

  validation {
    condition     = !var.deploy_agentic_containers || can(regex("^[0-9a-f]{40}$", var.agentic_generator_revision))
    error_message = "Set agentic_generator_revision to a full commit SHA before enabling container deployment."
  }
}

variable "agentic_llm_domains" {
  type        = list(string)
  description = "Explicit LLM provider hostnames permitted by the agent runtime egress proxy."
  default     = ["api.anthropic.com"]

  validation {
    condition = length(var.agentic_llm_domains) > 0 && alltrue([
      for domain in var.agentic_llm_domains : can(regex("^[A-Za-z0-9][A-Za-z0-9.-]*$", domain))
    ])
    error_message = "Supply explicit LLM hostnames, without schemes, ports, or wildcards."
  }
}

variable "mcp_image" {
  type        = string
  description = "Release-compatible hosted MCP image, pinned by version tag or sha256 digest."
  default     = ""

  validation {
    condition = !var.deploy_agentic_containers || (
      can(regex("^[A-Za-z0-9./_-]+:[0-9][A-Za-z0-9._-]*$", var.mcp_image)) ||
      can(regex("^[A-Za-z0-9./:_-]+@sha256:[0-9a-f]{64}$", var.mcp_image))
    )
    error_message = "Set mcp_image to a version-pinned image or sha256 digest, not latest."
  }
}

variable "agentic_root_volume_size" {
  type        = number
  description = "Root gp3 volume size in GiB when agentic containers are enabled, including sandbox writable layers."
  default     = 150

  validation {
    condition     = var.agentic_root_volume_size >= 100 && floor(var.agentic_root_volume_size) == var.agentic_root_volume_size
    error_message = "agentic_root_volume_size must be a whole number of at least 100 GiB."
  }
}