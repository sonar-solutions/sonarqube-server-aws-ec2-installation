#!/bin/bash

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

# Set temporary password for ec2-user (for debugging using the EC2 serial console)
# echo "ec2-user:<put_password_here>" | chpasswd 

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
useradd -m sonarqube
groupadd sonarqube
usermod -aG sonarqube sonarqube

# Back up the original sonar.properties file for future reference
mv sonarqube/conf/sonar.properties sonarqube/conf/sonar.default.properties

# Configure the SonarQube Server sonar.properties file
cat <<EOF | tee ${path}/sonarqube/conf/sonar.properties > /dev/null
# DATABASE
sonar.jdbc.url=$jdbcUrl
sonar.jdbc.username=$dbUsername
sonar.jdbc.password=$dbPassword
EOF

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