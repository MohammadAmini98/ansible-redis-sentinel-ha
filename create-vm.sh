#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
TEMPLATE="${TEMPLATE:-$IMAGE_DIR/fresh-clone.qcow2}"
NETWORK="${NETWORK:-default}"
RAM_MB="${RAM_MB:-4096}"
VCPUS="${VCPUS:-2}"
SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-300}"

CALLER_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    CALLER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$CALLER_HOME/.ssh/id_rsa.pub}"

usage() {
    cat <<'EOF'
Usage: ./create-vm.sh [VM_NAME] [HOSTNAME] [USERNAME]

Missing values are requested interactively. USERNAME defaults to ubuntu.

Environment overrides:
  IMAGE_DIR, TEMPLATE, NETWORK, SSH_PUBLIC_KEY, RAM_MB, VCPUS,
  SSH_WAIT_SECONDS
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

for command_name in virsh virt-install virt-customize qemu-img ssh ssh-keygen openssl; do
    command -v "$command_name" >/dev/null 2>&1 || die "'$command_name' is not installed."
done
command -v sudo >/dev/null 2>&1 || die "'sudo' is not installed."

[[ -f "$TEMPLATE" ]] || die "Template not found: $TEMPLATE"
[[ -f "$SSH_PUBLIC_KEY" ]] || die "SSH public key not found: $SSH_PUBLIC_KEY"

SSH_PRIVATE_KEY="${SSH_PUBLIC_KEY%.pub}"
[[ -f "$SSH_PRIVATE_KEY" ]] || die "SSH private key not found: $SSH_PRIVATE_KEY"

SSH_KEY="$(tr -d '\r\n' < "$SSH_PUBLIC_KEY")"
printf '%s\n' "$SSH_KEY" | ssh-keygen -lf - >/dev/null 2>&1 || \
    die "Invalid SSH public key: $SSH_PUBLIC_KEY"

VM_NAME="${1:-}"
HOSTNAME="${2:-}"
USERNAME="${3:-ubuntu}"

[[ -n "$VM_NAME" ]] || read -rp "VM name: " VM_NAME
[[ -n "$HOSTNAME" ]] || read -rp "Hostname [$VM_NAME]: " HOSTNAME
HOSTNAME="${HOSTNAME:-$VM_NAME}"

[[ "$VM_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "Invalid VM name: $VM_NAME"
[[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die "Invalid hostname: $HOSTNAME"
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username: $USERNAME"

sudo -v
sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1 && die "VM '$VM_NAME' already exists."
sudo virsh net-info "$NETWORK" >/dev/null 2>&1 || die "Libvirt network '$NETWORK' does not exist."

DISK="$IMAGE_DIR/${VM_NAME}.qcow2"
[[ ! -e "$DISK" ]] || die "Disk already exists: $DISK"

DISK_CREATED=false
DOMAIN_CREATED=false

cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )) && [[ "$DISK_CREATED" == true && "$DOMAIN_CREATED" == false ]]; then
        sudo rm -f "$DISK"
    fi
}
trap cleanup EXIT

MAC="52:54:00:$(openssl rand -hex 3 | sed 's/\(..\)/\1:/g;s/:$//')"

cat <<EOF

VM configuration
  Name:       $VM_NAME
  Hostname:   $HOSTNAME
  User:       $USERNAME
  Address:    assigned dynamically by libvirt DHCP
  MAC:        $MAC
  Memory:     $RAM_MB MiB
  vCPUs:      $VCPUS
  Disk:       $DISK
  SSH key:    $SSH_PUBLIC_KEY
EOF

printf '\nCreating overlay disk...\n'
sudo qemu-img create -f qcow2 -F qcow2 -b "$TEMPLATE" "$DISK"
DISK_CREATED=true

printf '\nConfiguring SSH and guest identity...\n'
sudo virt-customize \
    -a "$DISK" \
    --hostname "$HOSTNAME" \
    --run-command "id '$USERNAME' >/dev/null 2>&1 || useradd -m -s /bin/bash '$USERNAME'" \
    --run-command "usermod -aG sudo '$USERNAME'" \
    --ssh-inject "$USERNAME:string:$SSH_KEY" \
    --run-command "passwd -l '$USERNAME'" \
    --run-command "printf '%s\n' '$USERNAME ALL=(ALL) NOPASSWD:ALL' > '/etc/sudoers.d/$USERNAME'" \
    --run-command "chmod 0440 '/etc/sudoers.d/$USERNAME'" \
    --run-command "test -x /usr/sbin/sshd || { echo 'openssh-server is not installed in the template' >&2; exit 1; }" \
    --run-command "mkdir -p /etc/ssh/sshd_config.d" \
    --run-command "printf '%s\n' 'PubkeyAuthentication yes' 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/99-kvm-provisioning.conf" \
    --run-command "rm -f /etc/ssh/ssh_host_* && ssh-keygen -A" \
    --run-command "systemctl enable ssh.service" \
    --run-command "mkdir -p /etc/cloud/cloud.cfg.d && printf '%s\n' 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" \
    --run-command "rm -f /etc/netplan/*.yaml" \
    --run-command "printf '%s\n' 'network:' '  version: 2' '  renderer: networkd' '  ethernets:' '    dhcp:' '      match:' '        name: \"e*\"' '      dhcp4: true' '      dhcp6: false' '      optional: true' > /etc/netplan/99-kvm-dhcp.yaml" \
    --run-command "chmod 0600 /etc/netplan/99-kvm-dhcp.yaml" \
    --run-command "rm -f /var/lib/dhcp/* /var/lib/NetworkManager/*lease* 2>/dev/null || true" \
    --run-command "rm -rf /var/lib/cloud/instances/*" \
    --run-command "truncate -s 0 /etc/machine-id" \
    --run-command "rm -f /var/lib/dbus/machine-id"

printf '\nCreating and starting VM...\n'
sudo virt-install \
    --name "$VM_NAME" \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --disk "path=$DISK,format=qcow2,bus=virtio" \
    --network "network=$NETWORK,model=virtio,mac=$MAC" \
    --os-variant ubuntu22.04 \
    --import \
    --graphics none \
    --noautoconsole \
    --autostart
DOMAIN_CREATED=true

printf '\nWaiting up to %s seconds for a DHCP lease...\n' "$SSH_WAIT_SECONDS"
deadline=$((SECONDS + SSH_WAIT_SECONDS))
VM_IP=""
until [[ -n "$VM_IP" ]]; do
    VM_IP="$(
        sudo virsh net-dhcp-leases "$NETWORK" --mac "$MAC" 2>/dev/null |
        awk '$4 == "ipv4" {split($5, address, "/"); print address[1]; exit}'
    )"
    if (( SECONDS >= deadline )); then
        die "VM is running, but libvirt did not report a DHCP lease for MAC $MAC within ${SSH_WAIT_SECONDS}s."
    fi
    [[ -n "$VM_IP" ]] || sleep 5
done

printf 'DHCP assigned %s\n' "$VM_IP"
printf '\nWaiting for SSH...\n'
deadline=$((SECONDS + SSH_WAIT_SECONDS))
until ssh \
    -i "$SSH_PRIVATE_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$USERNAME@$VM_IP" true >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
        die "VM is running at $VM_IP, but SSH did not become ready within ${SSH_WAIT_SECONDS}s."
    fi
    sleep 5
done

cat <<EOF

VM created successfully
  Name:     $VM_NAME
  Hostname: $HOSTNAME
  Address:  $VM_IP
  MAC:      $MAC
  State:    $(sudo virsh domstate "$VM_NAME")

Connect with:
  ssh -i $SSH_PRIVATE_KEY $USERNAME@$VM_IP
EOF
