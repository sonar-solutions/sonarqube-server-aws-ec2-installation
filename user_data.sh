#!/bin/bash

%{ if deploy_agentic_containers ~}
set -euo pipefail
umask 077
%{ endif ~}

# Variables
# The url to download SonarQube zip file from (passed from Terraform)
url="${url}"

# The path where SonarQube will be downloaded and unzipped
path="${path}"

# The name of saved zip file
zipFileName="${zip_filename}"

# Database connection URL
jdbcUrl="${jdbc_url}"

# Database username
dbUsername="${db_username}"

# Database password
dbPassword="${db_password}"

# Update and upgrade OS packages
dnf update -y

# Install prerequisite packages
dnf install unzip wget net-tools java-25-amazon-corretto-devel postgresql17 -y

# Configure ElasticSearch prerequisites
cat <<EOF | tee /etc/sysctl.d/99-sonarqube.conf > /dev/null
vm.max_map_count=524288
fs.file-max=131072
EOF

# The above ElasticSearch prerequisites must be applied
sysctl -p /etc/sysctl.d/99-sonarqube.conf

# Download SonarQube Server
echo "Downloading SonarQube Server from $url to $path"
cd $path
wget -O $zipFileName $url
# Extract the zip file quietly
echo "Extracting $zipFileName to $path"
unzip -q $zipFileName
rm $zipFileName
mv sonarqube-* sonarqube

# create sonarqube user and group
echo "Creating sonarqube user and group"
groupadd sonarqube
useradd -m -g sonarqube sonarqube
usermod -aG sonarqube sonarqube

%{ if deploy_agentic_containers ~}
dnf install docker git jq python3 openssl zstd -y
systemctl enable --now docker

composeVersion="v2.39.4"
composeArch=$(uname -m)
composeUrl="https://github.com/docker/compose/releases/download/$composeVersion"
install -d -m 755 /usr/local/lib/docker/cli-plugins
downloadDir=$(mktemp -d)
cd "$downloadDir"
wget -q "$composeUrl/docker-compose-linux-$composeArch" "$composeUrl/docker-compose-linux-$composeArch.sha256"
sha256sum -c "docker-compose-linux-$composeArch.sha256"
install -m 755 "docker-compose-linux-$composeArch" /usr/local/lib/docker/cli-plugins/docker-compose

gvisorUrl="https://storage.googleapis.com/gvisor/releases/release/latest/$composeArch"
wget -q "$gvisorUrl/gvisor.tar.zstd" "$gvisorUrl/gvisor.tar.zstd.sha512"
sha512sum -c gvisor.tar.zstd.sha512
tar --zstd -xf gvisor.tar.zstd -C /usr/local/bin
chmod -R a+rX /usr/local/bin/gvisor-bin
chmod 755 /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1
install -d -m 755 /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
	printf '{}\n' > /etc/docker/daemon.json
fi
jq '.runtimes.runsc = {path: "/usr/local/bin/runsc", runtimeArgs: ["--network=host", "--overlay2=root:self,size=50g"]}' \
	/etc/docker/daemon.json > "$downloadDir/daemon.json"
install -m 644 "$downloadDir/daemon.json" /etc/docker/daemon.json
systemctl restart docker

agenticHome="$path/agentic"
storagePath="$path/agentic-storage"
signingPath="$path/sonarqube/conf/agentic-signing"
install -d -m 700 "$agenticHome"
install -d -m 750 -o sonarqube -g sonarqube "$signingPath"
install -d -m 1777 "$storagePath" "$storagePath/hunter" "$storagePath/remediation"
git init "$agenticHome/generator"
git -C "$agenticHome/generator" remote add origin https://github.com/SonarSource/docker-sonarqube.git
git -C "$agenticHome/generator" fetch --depth 1 origin '${agentic_generator_revision}'
git -C "$agenticHome/generator" checkout --detach FETCH_HEAD
generatorPath="$agenticHome/generator/agentic-compose-generator"
jq -e '[.["agent-orchestrator"], .["hunter-agent"], .["remediation-agent"], .vortex] | all(.tag | startswith("2026.5."))' \
	"$generatorPath/default-images.json" > /dev/null

cat <<'EOF' > "$agenticHome/profile.json"
${agentic_profile}
EOF
umask 022
python3 "$generatorPath/generate.py" --profile "$agenticHome/profile.json" --out "$agenticHome/bundle"
umask 077
chmod 700 "$agenticHome/bundle"
chmod 755 "$agenticHome/bundle/egress-proxy/entrypoint.sh"
chmod 644 "$agenticHome/bundle/egress-proxy/squid.conf.template"
rm "$agenticHome/profile.json"
cd "$agenticHome/bundle"
install -d -m 755 custom-ca
wget -q -O custom-ca/rds-ca.pem 'https://truststore.pki.rds.amazonaws.com/${aws_region}/${aws_region}-bundle.pem'
chmod 644 custom-ca/rds-ca.pem
javaHome=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
truststorePath="$path/sonarqube/conf/rds-truststore"
cp "$javaHome/lib/security/cacerts" "$truststorePath"
cd "$downloadDir"
awk '/-----BEGIN CERTIFICATE-----/ {certificateIndex++} certificateIndex {print > ("rds-cert-" certificateIndex ".pem")}' \
	"$agenticHome/bundle/custom-ca/rds-ca.pem"
for certificate in rds-cert-*.pem; do
	keytool -importcert -noprompt -alias "$certificate" -file "$certificate" \
		-keystore "$truststorePath" -storepass changeit
done
chmod 640 "$truststorePath"
cd "$agenticHome/bundle"

cat <<'EOF' >> .env
ORCHESTRATOR_PUBLISH_PORT=127.0.0.1:9091
VORTEX_PUBLISH_PORT=127.0.0.1:9092
EOF
cat <<'EOF' > docker-compose.override.yaml
{"services":{"mcp":{"image":"${mcp_image}","restart":"unless-stopped","environment":{"STORAGE_PATH":"/data","SONARQUBE_URL":"http://host.docker.internal:9000","SONARQUBE_HTTP_HOST":"0.0.0.0","SONARQUBE_HTTP_PORT":"8080","SONARQUBE_TRANSPORT":"http"},"extra_hosts":["host.docker.internal:host-gateway"],"ports":["127.0.0.1:9093:8080"],"volumes":["mcp_data:/data"],"networks":["control"]}},"volumes":{"mcp_data":{}}}
EOF
docker compose config --quiet
orchestratorImage=$(docker compose config --format json | jq -r '.services.orchestrator.image')
sed -n 's/^AGENTIC_SIGNING_SECRET=//p' .env > "$signingPath/instance-secret"
test -s "$signingPath/instance-secret"
docker run --rm --user 0:0 -v "$signingPath:/run/agentic-signing" \
	--entrypoint /derive-keys.sh "$orchestratorImage" \
	--secret-file /run/agentic-signing/instance-secret \
	--label agentic-shared=/run/agentic-signing/agentic-shared.key
chown -R sonarqube:sonarqube "$signingPath"
chmod 600 "$signingPath/instance-secret" "$signingPath/agentic-shared.key"
jdbcUrl="$jdbcUrl?sslmode=verify-full&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory"
cd "$path"
rm -rf "$downloadDir"
%{ endif ~}

# Back up the original sonar.properties file for future reference
mv sonarqube/conf/sonar.properties sonarqube/conf/sonar.default.properties

# Configure the SonarQube Server sonar.properties file
cat <<EOF | tee ${path}/sonarqube/conf/sonar.properties > /dev/null
# DATABASE
sonar.jdbc.url=$jdbcUrl
sonar.jdbc.username=$dbUsername
sonar.jdbc.password=$dbPassword
EOF

%{ if deploy_agentic_containers ~}
cat <<EOF >> "$path/sonarqube/conf/sonar.properties"
sonar.hunteragent.orchestrator.url=http://127.0.0.1:9091
sonar.remediationagent.orchestrator.url=http://127.0.0.1:9091
sonar.vortex.enabled=true
sonar.vortex.analysis.url=http://127.0.0.1:9092
sonar.agentic.storage.type=FILESYSTEM
sonar.agentic.storage.filesystem.base-dir=$storagePath
sonar.agentic.orchestrator.storage.type=FILESYSTEM
sonar.agentic.orchestrator.storage.filesystem.base-dir=$storagePath
sonar.agentic.signing.secretFile=$signingPath/instance-secret
sonar.agentic.orchestrator.signingKeyPath=$signingPath/agentic-shared.key
sonar.mcp.enabled=true
sonar.mcp.serverUrl=http://127.0.0.1:9093
sonar.mcp.healthCheckInterval=30
sonar.web.javaAdditionalOpts=-Djavax.net.ssl.trustStore=$truststorePath -Djavax.net.ssl.trustStorePassword=changeit
sonar.ce.javaAdditionalOpts=-Djavax.net.ssl.trustStore=$truststorePath -Djavax.net.ssl.trustStorePassword=changeit
EOF
chmod 640 "$path/sonarqube/conf/sonar.properties"
%{ endif ~}

# Change ownership of the SonarQube directory to the sonarqube user
chown -R sonarqube:sonarqube ${path}/sonarqube

# Create systemd service file for SonarQube service
# Find the SonarQube application JAR file. This file will be called by the systemd service.
# The file contains the version number in its name, so use a wildcard to find it.
SONAR_JAR=$(find ${path}/sonarqube/lib -name "sonar-application-*.jar")

cat <<EOF | tee /etc/systemd/system/sonarqube.service > /dev/null
[Unit]
Description=SonarQube Server service
After=syslog.target network.target

[Service]
Type=simple
User=sonarqube
Group=sonarqube
PermissionsStartOnly=true
ExecStart=/bin/nohup /usr/bin/java -Xms32m -Xmx32m -Djava.net.preferIPv4Stack=true -jar $SONAR_JAR
StandardOutput=journal
LimitNOFILE=131072
LimitNPROC=8192
TimeoutStartSec=5
Restart=never
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

# Install SonarQube: Set up SonarQube as a service
#   The systemd service file is created and saved where it needs to be.
systemctl enable sonarqube.service
echo "Enabled SonarQube service"
systemctl start sonarqube.service
echo "Started SonarQube service"
systemctl status sonarqube.service

%{ if deploy_agentic_containers ~}
cat <<EOF > /etc/systemd/system/sonarqube-agentic.service
[Unit]
Description=SonarQube agentic containers and hosted MCP
Requires=docker.service sonarqube.service
After=docker.service sonarqube.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$agenticHome/bundle
ExecStart=/usr/bin/docker compose up -d --wait --wait-timeout 600
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=900
TimeoutStopSec=0

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sonarqube-agentic.service

ready=false
for attempt in $(seq 1 120); do
	serverStatus=$(wget -qO- --timeout=5 http://127.0.0.1:9000/api/system/status | jq -r '.status // empty') || serverStatus=""
	if [ "$serverStatus" = "UP" ]; then
		ready=true
		break
	fi
	if [ "$serverStatus" = "DB_MIGRATION_NEEDED" ] || [ "$serverStatus" = "DB_MIGRATION_RUNNING" ]; then
		echo "Complete the SonarQube database migration at /setup, then run systemctl start sonarqube-agentic.service" >&2
		exit 1
	fi
	sleep 5
done
if [ "$ready" != true ]; then
	echo "SonarQube did not become ready; inspect journalctl -u sonarqube.service, then start sonarqube-agentic.service" >&2
	exit 1
fi
systemctl start sonarqube-agentic.service
%{ endif ~}