# SonarQube Server Enterprise Edition on AWS EC2

This Terraform configuration deploys a single-node SonarQube Server Enterprise
Edition installation on AWS EC2, with a PostgreSQL RDS database and a public
HTTPS endpoint. Choose the server version through its distribution ZIP URL and
select Linux or Windows for the EC2 host.

Agentic containers are optional. They were introduced in SonarQube Server
2026.5 and are deployed alongside the server when the selected version and OS
support this repository's container deployment.

## How It Works

1. Creates a VPC, public/private subnets, internet gateway, and NAT gateway, or
	 uses an existing VPC and subnet IDs supplied in the configuration.
2. Creates an encrypted PostgreSQL RDS instance in the private subnets and
	 generates its database password.
3. Creates an EC2 key pair, launch template, and Auto Scaling group with one
	 desired application instance.
4. Runs an OS-specific bootstrap that downloads the selected SonarQube ZIP,
	 installs Java, configures the database connection, and installs the server
	 as a system service.
5. Creates a public Network Load Balancer, a Route 53 application alias in an
	 existing hosted zone, and an ACM certificate validated through DNS.
6. Optionally installs Docker and starts the 2026.5 agentic containers on Linux.
	 Windows deployments provision a separate private Amazon Linux agent host,
	 encrypted S3 storage, and a private TLS callback endpoint. The server itself
	 continues to run from the ZIP installation.

The Linux bootstrap is [user_data.sh](user_data.sh); the Windows bootstrap is
[user_data.ps1](user_data.ps1). Infrastructure is defined in
[terraform.tf](terraform.tf), and all inputs are described in
[variables.tf](variables.tf).

## Prerequisites

- Terraform 1.9 or later, required by the cross-variable input validation.
- AWS credentials with permissions to manage the configured EC2, networking,
	Auto Scaling, RDS, Route 53, and ACM resources. Windows agentic deployments
	also require S3 and IAM management permissions.
- An existing public Route 53 hosted zone in the target account, with working
	public delegation. See DNS And HTTPS below.
- Outbound connectivity from the private application subnets to download the
	selected distribution, Java, and OS packages. Container deployments also need
	GitHub, Docker Hub, the gVisor release bucket, RDS CA downloads, and the
	configured external services.
- A valid Enterprise Edition license to use licensed server capabilities.
	Agent features require the corresponding subscriptions and integrations.

## Configuration

Configure the local [terraform.tfvars.json](terraform.tfvars.json) using
[terraform.tfvars.json.sample](terraform.tfvars.json.sample) as a reference.
The sample currently demonstrates Linux with 2026.5 and agentic containers;
the installer is not limited to that server version when containers are off.

| Inputs | Purpose |
| --- | --- |
| `aws_region`, `owner` | AWS region and resource ownership tags |
| `installation_os`, `instance_type` | `linux` or `windows`, and EC2 sizing |
| `ami_family`, `ami_id` | OS-compatible AMI family and optional pinned Amazon-owned AMI ID |
| `agentic_instance_type` | Separate Linux agent instance size when Windows agentic deployment is enabled |
| `zip_download_url`, `zip_filename` | Server release to install and local ZIP filename |
| `vpc_id`, `private_subnets`, `public_subnets` | New or existing network configuration |
| `vpc_name`, `vpn_cidr`, `availability_zones` | Network name, VPC CIDR, and zones when creating a VPC |
| `hostname`, `domain_name` | Application host label and existing public hosted-zone name |
| `rds_name`, `rds_instance_type`, `rds_engine_version` | PostgreSQL database identity, sizing, and version |
| `linux_sonar_dir`, `win_sonar_dir` | OS-specific installation directory |
| `win_java_url`, `win_java_filename` | Java MSI used by the Windows bootstrap |
| `enable_rdp`, `rdp_allowed_cidr` | Optional Windows RDP access through the NLB |
| `install_chromium` | Chromium installation setting for the Windows bootstrap |

For a new VPC, leave `vpc_id` null and provide `vpc_name`, `vpn_cidr`,
`availability_zones`, and CIDR blocks in both subnet lists. Subnet CIDRs follow
the order of the availability zones. `vpn_cidr` names the VPC CIDR input; it does
not create a VPN.

For an existing VPC, set `vpc_id` and supply subnet IDs instead of CIDRs. Provide
private subnets suitable for RDS and the application, and public subnets with
internet-gateway routing for the public NLB. Ensure the application subnets have
outbound connectivity. Restrict `rdp_allowed_cidr` when enabling RDP.

`ami_family=auto` selects Amazon Linux 2023 or Windows Server 2025 according to
`installation_os`. Windows also accepts `windows-2019` and `windows-2022`.
The latest standard English Full Base x86_64 image is selected, or `ami_id` can
pin a specific revision within the chosen family. These are bootstrap targets,
not a claim that arbitrary AMIs or every revision have been runtime-tested.
Linux bootstrap requires Amazon Linux 2023; Ubuntu, other Linux distributions,
Windows Core, and ARM64 images are not supported.

### Selecting A Server Version

`zip_download_url` selects the exact server release. Set it to the Enterprise
distribution URL for the version you want; there is no separate server-version
input. The selected release must support the configured Java and PostgreSQL
versions. Linux currently installs Corretto JDK 25; Windows uses `win_java_url`.
Selecting an older ZIP does not automatically downgrade those prerequisites.

For example, a server-only 2026.1 configuration uses these values:

```json
{
	"zip_download_url": "https://binaries.sonarsource.com/CommercialDistribution/sonarqube-enterprise/sonarqube-enterprise-2026.1.0.119033.zip",
	"deploy_agentic_containers": false
}
```

For 2026.5 with agentic containers, use these values alongside the other required
infrastructure inputs:

```json
{
	"installation_os": "linux",
	"zip_download_url": "https://binaries.sonarsource.com/CommercialDistribution/sonarqube-enterprise/sonarqube-enterprise-2026.5.4.134003.zip",
	"deploy_agentic_containers": true,
	"agentic_generator_revision": "e563fe9973afa1435d555d9377fefcf93ee7fb3a",
	"agentic_llm_domains": ["api.anthropic.com"],
	"mcp_image": "sonarsource/sonarqube-mcp:1.27.1.4770",
	"agentic_root_volume_size": 150
}
```

### Version And OS Checks

| Selected server / OS | Containers disabled | Containers enabled |
| --- | --- | --- |
| Releases before 2026.5, Linux or Windows | Server-only deployment, subject to runtime compatibility | Rejected: agentic containers did not exist in those releases |
| 2026.5, Linux | Server-only deployment | Supported with matching pinned images and generator |
| 2026.5, Windows | Server-only deployment | Hybrid Windows server plus separate Linux agent host |
| Later release lines | Server-only deployment, subject to runtime compatibility | Not supported by the current 2026.5-pinned integration |

`deploy_agentic_containers` defaults to false. Enabling it does not upgrade the
server automatically. Terraform rejects an incompatible AMI family or ZIP release
before deployment, and the bootstrap verifies that the generator's agent image
tags belong to 2026.5. Later release lines need an explicitly compatible
generator/image update rather than reusing the 2026.5 images unchecked.

## Deploy And Update

```bash
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
terraform output sonarqube_url
```

Review the plan before applying. Keep variable files containing private values,
Terraform state, saved plans, and the generated private key out of version
control. The `nlb_dns_name`, `asg_name`, and `rds_endpoint` outputs identify the
load balancer, application group, and database. `private_key_path` identifies
the local private-key file.

This is a bootstrap-and-replace deployment, not an in-place software updater.
Changing the launch template triggers an Auto Scaling instance refresh. A new
EC2 instance installs the configured release and connects to the tracked RDS
database; an EC2 replacement alone does not recreate that database. Review RDS
changes separately and follow SonarQube's supported server-upgrade path.

To switch an existing deployment to Windows, keep the same Terraform state,
AWS region, network, hostname, and RDS inputs. Set `installation_os=windows`
and `ami_family=windows-2025` (or another listed Windows family). With containers
enabled, Terraform adds the hybrid resources and replaces the application EC2
instance. It does not intentionally replace RDS. Inspect a fresh plan and stop
if the database is marked for creation, destruction, or replacement. Do not
apply an old saved plan. This switch has downtime; back up RDS first.

This configuration is intended for fresh Terraform state. It does not contain
state moves for older ACM resources that were recorded at indexed addresses.
Before reusing a state from an older configuration, migrate those addresses
manually and review the plan to ensure the certificate and listener will not be
recreated.

Back up the database before upgrades. Single-instance replacement can cause
downtime, and host-local files do not survive replacement. Terraform apply
completion does not establish that SonarQube or every container is healthy.

## Agentic Containers

The containers use Docker Engine and Docker Compose. With a Linux server they
run on the same EC2 instance. With a Windows server they run on a separate
Amazon Linux 2023 EC2 instance. ECS, EKS, and Kubernetes are not used.

When `deploy_agentic_containers` is true, the Linux EC2 user-data script:

1. Installs Docker, Docker Compose, and the gVisor `runsc` sandbox runtime.
2. Checks out `SonarSource/docker-sonarqube` at `agentic_generator_revision`.
3. Runs its official `agentic-compose-generator` in `edition=none` mode, using
	the existing SonarQube ZIP installation and RDS database.
4. Writes the generated bundle under `<linux_sonar_dir>/agentic/bundle` and adds
	hosted MCP through a Compose override.
5. Configures shared storage, signing keys, service URLs, and RDS certificate
	trust, then starts the bundle with `sonarqube-agentic.service` using
	`docker compose up -d --wait`.

The pinned generator selects these agent images:

| Component | Image |
| --- | --- |
| Agent Orchestrator | `sonarsource/sonarqube-agent-orchestrator:2026.5.2` |
| Hunter Agent runtime | `sonarsource/sonarqube-hunter-agent:2026.5.2` |
| Remediation Agent runtime | `sonarsource/sonarqube-remediation-agent:2026.5.1` |
| Vortex analysis | `sonarsource/sonar-vortex:2026.5.1` |
| Hosted MCP | `mcp_image`, currently `sonarsource/sonarqube-mcp:1.27.1.4770` in the sample |

The bundle also includes an egress proxy and one-shot storage, signing-key, and
truststore initialization containers. Hunter and Remediation use gVisor and
isolated Docker networks; their outbound requests pass through the proxy.
Changing the generator revision may change image versions and configuration.

Size the instance for SonarQube plus all enabled containers. The sample uses
`m6a.2xlarge` (32 GiB RAM), with `agentic_root_volume_size=150` for the encrypted
gp3 root disk. That disk setting applies when containers are enabled and must be
at least 100 GiB; it is not the RDS storage size.

### Windows Hybrid Deployment

Windows agentic mode adds a Linux agent instance sized by `agentic_instance_type`
(default `m6a.2xlarge`), a private NLB, a private DNS zone, two private encrypted
S3 buckets, and narrowly scoped IAM identities. These have additional AWS costs.
All agent images and the gVisor sandbox remain on Linux; Windows does not need
Docker Desktop, WSL, nested virtualization, or an unsandboxed fallback.

The Windows ASG continues to use the original RDS instance and public HTTPS
endpoint. Inside the VPC, the same SonarQube hostname resolves to the private
TLS listener for agent callbacks. Windows reaches Orchestrator, Vortex, and MCP
at `agentic.<hostname>.<domain_name>` on TLS ports 8443, 8444, and 8445. Only the
application security group can reach those ports. The private NLB terminates
TLS before forwarding to Windows on port 9000, as the public NLB does.

Shared contexts/jobs use S3 rather than an OS-specific filesystem path. A
separate bootstrap bucket holds the Windows installation script and persisted
signing identity/TLS material. Instance roles restrict bootstrap access; the
storage-only IAM access key cannot read bootstrap objects. Storage credentials
are explicitly configured for the pinned generator on both platforms. They
are sensitive Terraform state/user-data/bootstrap values: protect the backend,
plans, buckets, and administrator access, and rotate the key as needed. Do not
use a backend accessible to untrusted users.

Windows downloads its full bootstrap into an administrator/SYSTEM-only
directory, keeping EC2 user data below 16 KiB. The Linux host publishes the
signing key and CA before Windows starts SonarQube; containers wait until the
server reports UP. Signing identity and the service certificates are reused
when the Linux host is replaced. Bootstrap changes require an application
instance refresh so Windows reloads the generated configuration.

The hybrid Linux bundle lives at `/opt/sonarqube-agentic/bundle`. Shared S3
contexts and jobs can contain provider credentials; treat both buckets as
credential stores, not ordinary artifact buckets.

## DNS And HTTPS

`domain_name` must match an existing public Route 53 hosted zone in the AWS
account used by Terraform. The module looks up that zone and creates the
application DNS alias; it does not create, register, or delegate the domain.
Public DNS resolution requires the domain owner to delegate to that hosted zone.
Private hosted zones are not currently supported.

The load balancer uses the original HTTPS configuration: Terraform requests an
ACM certificate, creates its DNS validation record, and attaches the validated
certificate to a TLS listener on port 443. The application URL is
`https://<hostname>.<domain_name>`. There is no ACM opt-out or HTTP listener.

For example, `hostname=sq0` and `domain_name=example.com` produce
`https://sq0.example.com`. Merely creating a hosted zone does not establish
public delegation. ACM validation cannot finish unless its CNAME is visible
through authoritative public DNS. The AWS-generated NLB hostname is not covered
by the certificate for your application hostname.

## Activation

If SonarQube reports that database migration is needed, complete `/setup` in the
browser. In a Linux-only agentic deployment, then run
`sudo systemctl start sonarqube-agentic.service` if bootstrap paused for that
migration. The hybrid Linux service retries automatically until the Windows
server reports UP. Check Administration > System for component health.

Install the appropriate license in License Manager. Deploying a container does
not itself license or enable its feature in SonarQube.

Agent jobs additionally require the appropriate license subscriptions, DevOps
integration, and an LLM provider configured in SonarQube. The default egress
allowlist permits `api.anthropic.com`; change `agentic_llm_domains` for your
provider. Do not put provider credentials in Terraform variable files.

## Storage And Ports

On Linux-only deployments, shared agent files live under
`<linux_sonar_dir>/agentic-storage` and are lost on instance replacement. Hybrid
deployments use the private S3 jobs bucket, which survives host replacement.
MCP data uses a local Docker volume and is lost on agent-host replacement in
both modes. Hybrid buckets refuse deletion while nonempty; back up and review
their contents before cleanup. Generated bundle
files contain credentials and signing material; do not copy them into Git.

In Linux-only mode, Orchestrator, Vortex, and MCP publish only on host loopback
at ports 9091, 9092, and 9093. Their host-side connections use HTTP; hybrid mode
uses the private TLS endpoints described above. Requests between the
agentic components use the official signing keys. Agent jobs use gVisor and the
generator's restricted networks and egress proxy. RDS connections verify TLS
certificates using the regional RDS CA bundle.

RDS has seven-day automated backup retention in this configuration, but deletion
protection is disabled and final snapshots are skipped on deletion. Review these
settings and take an independent backup before destroying the deployment.

Deployment reference: [official Compose generator](https://github.com/SonarSource/docker-sonarqube/tree/master/agentic-compose-generator).