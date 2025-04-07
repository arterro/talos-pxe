#!/usr/bin/env bash

set -e

MATCHBOX_IP="192.168.22.146"

declare -a NODES=(
    "uruz:192.168.22.154,6c:4b:90:4f:be:b1"
    "fehu:192.168.22.155,6c:4b:90:4f:be:56"
    "berkano:192.168.22.156,6c:4b:90:23:c8:c7"
)

FIRST_NODE="${NODES[0]}"
DATA="${FIRST_NODE#*:}"
FIRST_CP_IP="${DATA%%,*}"

LATEST_TALOS_VERSION=$(curl -s https://api.github.com/repos/siderolabs/talos/releases | jq -r 'map(select(.prerelease == false)) | .[0].tag_name')
TALOS_CONFIG_DIR="${HOME}/.talos"
CUR_DIR=$(dirname "$(realpath "${0}")")
TLS_DIR=$(realpath "${CUR_DIR}/tls")
SCRIPT_ROOT_DIR=$(realpath "${CUR_DIR}/..")
MATCHBOX_ETC_DIR="${SCRIPT_ROOT_DIR}/matchbox/etc/matchbox"
MATCHBOX_ASSETS_DIR="${SCRIPT_ROOT_DIR}/matchbox/var/lib/matchbox/assets"
MATCHBOX_GROUPS_DIR="${SCRIPT_ROOT_DIR}/matchbox/var/lib/matchbox/groups"
MATCHBOX_PROFILES_DIR="${SCRIPT_ROOT_DIR}/matchbox/var/lib/matchbox/profiles"

mkdir -p "${MATCHBOX_ETC_DIR}"
mkdir -p "${MATCHBOX_ASSETS_DIR}"
mkdir -p "${MATCHBOX_GROUPS_DIR}"
mkdir -p "${MATCHBOX_PROFILES_DIR}"

# We will be using Talos Image Factory to enable extensions
# which will be necessary for when we install Longhorn
echo "Downloading vmlinuz and initramfs files for Talos ${LATEST_TALOS_VERSION} via Talos Image Factory"
schematic_id=$(curl -sX POST --data-binary @"${CUR_DIR}/extensions.yaml" https://factory.talos.dev/schematics | jq -r '.id')
curl -L "https://factory.talos.dev/image/${schematic_id}/${LATEST_TALOS_VERSION}/kernel-amd64" \
     --output "${MATCHBOX_ASSETS_DIR}/vmlinuz"
curl -L "https://factory.talos.dev/image/${schematic_id}/${LATEST_TALOS_VERSION}/initramfs-amd64.xz" \
     --output "${MATCHBOX_ASSETS_DIR}/initramfs.xz"

echo "Generating autoexec.ipxe for Matchbox"
cat > "${SCRIPT_ROOT_DIR}/matchbox/autoexec.ipxe" << EOF
#!ipxe
dhcp
chain http://${MATCHBOX_IP}:8080/boot.ipxe
EOF

echo "Generating Matchbox TLS files for gRPC"
echo "${TLS_DIR}"
SAN="IP.1:${MATCHBOX_IP}" "${TLS_DIR}/cert-gen" 
openssl verify -CAfile "${TLS_DIR}/ca.crt" "${TLS_DIR}/server.crt"
openssl verify -CAfile "${TLS_DIR}/ca.crt" "${TLS_DIR}/server.crt"
mv "${TLS_DIR}/ca.crt" "${TLS_DIR}/server.crt" "${TLS_DIR}/server.key" "${MATCHBOX_ETC_DIR}"

# Generate talosconfig once, before iterating through the nodes and generating their configuration
mkdir -p "${TALOS_CONFIG_DIR}"
talosctl gen secrets --force -o "${TALOS_CONFIG_DIR}/secrets.yaml"
talosctl gen config valhalla "https://${FIRST_CP_IP}:6443" \
  --force \
  --with-secrets "${TALOS_CONFIG_DIR}/secrets.yaml" \
  --config-patch @general.yaml \
  --output-types talosconfig \
  --output "${TALOS_CONFIG_DIR}/config"
talosctl config endpoint "${FIRST_CP_IP}"
talosctl config node "${FIRST_CP_IP}"

for node in "${NODES[@]}"; do
    node_name="${node%%:*}"
    data="${node#*:}"
    ip="${data%%,*}"
    mac_address="${data#*,}"

    # Generates the control plane configurations
    # Since we are using three nodes and will make all three act as control planes and workers
    # This will be under assets for Matchbox
    talosctl gen config valhalla "https://${FIRST_CP_IP}:6443" \
        --force \
        --with-secrets "${TALOS_CONFIG_DIR}/secrets.yaml" \
        --with-docs=false \
        --with-examples=false \
        --config-patch @general.yaml \
        --output-types controlplane \
        --config-patch "$(cat <<EOF
machine:
  install:
    image: "factory.talos.dev/installer/${schematic_id}:${LATEST_TALOS_VERSION}"
  network:
    hostname: ${node_name}
    interfaces:
    - deviceSelector:
        physical: true
      dhcp: true
      addresses: [${ip}/24]
      vip:
        ip: 192.168.22.222
cluster:
  allowSchedulingOnControlPlanes: true
EOF
)" \
        --output "${MATCHBOX_ASSETS_DIR}/${node_name}.yaml"
    talosctl validate --config "${MATCHBOX_ASSETS_DIR}/${node_name}.yaml" --mode metal
    
    jq -n \
        --arg id "${node_name}" \
        --arg name "${node_name}" \
        --arg profile "${node_name}" \
        --arg mac "${mac_address}" \
        '{
            id: $id, 
            name: $name, 
            profile: $profile, 
            selector: {
                mac: $mac
            }
        }' > "${MATCHBOX_GROUPS_DIR}/${node_name}.json"

    echo "Created ${MATCHBOX_GROUPS_DIR}/${node_name}.json"

    jq -n \
        --arg id "${node_name}" \
        --arg name "${node_name}" \
        --arg kernel "/assets/vmlinuz" \
        --arg initrd "/assets/initramfs.xz" \
        --arg talos_config "http://${MATCHBOX_IP}:8080/assets/${node_name}.yaml" \
        '{
            id: $id, 
            name: $name, 
            boot: {
                kernel: "/assets/vmlinuz", 
                initrd: ["/assets/initramfs.xz"], 
                args: [
                    "initrd=initramfs.xz",
                    "init_on_alloc=1",
                    "slab_nomerge",
                    "pti=on",
                    "console=tty0",
                    "console=ttyS0",
                    "printk.devkmsg=on",
                    "talos.platform=metal",
                    ("talos.config=" + $talos_config)
                ]
            }
        }' > "${MATCHBOX_PROFILES_DIR}/${node_name}.json"

    echo "Created ${MATCHBOX_PROFILES_DIR}/${node_name}.json"
done
