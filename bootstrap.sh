#!/bin/bash

# We need to provide the following params when calling this script:
# Param 1 - wifi IP for Kubernetes master
# Param 2 - Kubernetes bootstrap token

# Install Dockah
sudo apt install -y docker.io

# Create or replace the contents of /etc/docker/daemon.json to enable the systemd cgroup driver
sudo cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

# Append the cgroups and swap options to the kernel command line
# Note the space before "cgroup_enable=cpuset", to add a space after the last existing item on the line
sudo sed -i '$ s/$/ cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 swapaccount=1/' /boot/firmware/cmdline.txt

# Enable net.bridge.bridge-nf-call-iptables and -iptables6
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sudo sysctl --system

# Add the packages.cloud.google.com atp key
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

# Add the Kubernetes repo
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF

# Update the apt cache and install kubelet, kubeadm, and kubectl
# (Output omitted)
sudo apt update && sudo apt install -y kubelet kubeadm kubectl

# Disable (mark as held) updates for the Kubernetes packages
sudo apt-mark hold kubelet kubeadm kubectl

# -------------------------------------------------
# Setup post-reboot script
# -------------------------------------------------

if [ $(hostname -I | awk '{print $1;}') == $1 ] # master
then

  # K8s can't have all nodes called ubuntu, must have unique names, so set master to "master"
  sudo hostnamectl set-hostname master

  # Write a startup script for next boot
  sudo cat > /home/ubuntu/startup.sh <<EOF
sudo kubeadm init --token=$2 --kubernetes-version=v1.20.0 --pod-network-cidr=10.244.0.0/16

mkdir -p /root/.kube
sudo cp -i /etc/kubernetes/admin.conf /root/.kube/config
sudo chown $(id -u):$(id -g) /root/.kube/config

# Setup .kube/config for ubuntu user too, for troubleshooting
mkdir -p /home/ubuntu/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
sudo chown ubuntu:ubuntu /home/ubuntu/.kube
sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config

# Download the Flannel YAML data and apply it
curl -sSL https://raw.githubusercontent.com/coreos/flannel/v0.13.0/Documentation/kube-flannel.yml | kubectl apply -f -

rm -f /home/ubuntu/startup.sh
EOF
  sudo chmod 755 /home/ubuntu/startup.sh

  # Set cron to run startup.sh on next boot
  sudo chmod 757 /etc/cron.d
  sudo cat > /etc/cron.d/run_setup <<EOF
@reboot root sleep 60 && /home/ubuntu/startup.sh
EOF
  sudo chmod 755 /etc/cron.d
else
  # K8s can't have all nodes called ubuntu, must have unique names, so set worker node names to
  # "node" plus last octet of the wifi IP address
  sudo hostnamectl set-hostname $(echo "node"$(hostname -I | awk '{print $1;}' | cut -d"." -f4))

  # Write a startup script for next boot
  sudo cat > /home/ubuntu/startup.sh <<EOF
# Wait 5 minutes for the master to come up
sleep 600

# This allows us to pre-configure a token and then skip the CA cert hash (less secure, but good enough for our requirements):
sudo kubeadm join $1:6443 --token $2 --discovery-token-unsafe-skip-ca-verification

rm -f /home/ubuntu/startup.sh
EOF
  sudo chmod 755 /home/ubuntu/startup.sh

  # Set cron to run startup.sh on next boot
  sudo chmod 757 /etc/cron.d
  sudo cat > /etc/cron.d/run_setup <<EOF
@reboot root sleep 60 && /home/ubuntu/startup.sh
EOF
  sudo chmod 755 /etc/cron.d
fi

# Cleanup after this script
rm -f /home/ubuntu/bootstrap.sh

sudo shutdown now -r
