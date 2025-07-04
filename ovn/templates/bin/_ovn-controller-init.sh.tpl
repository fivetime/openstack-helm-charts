#!/bin/bash -xe

# Copyright 2023 VEXXHOST, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ANNOTATION_KEY="openstack-helm/ovn-system-id"

# Get a specific IPv4 address for original functionality (preserving original function)
function get_ip_address_from_interface {
  local interface=$1
  local ip=$(ip -4 -o addr s "${interface}" | awk '{ print $4; exit }' | awk -F '/' 'NR==1 {print $1}')
  if [ -z "${ip}" ] ; then
    exit 1
  fi
  echo ${ip}
}

# Get prefix from an IPv4 address for original functionality (preserving original function)
function get_ip_prefix_from_interface {
  local interface=$1
  local prefix=$(ip -4 -o addr s "${interface}" | awk '{ print $4; exit }' | awk -F '/' 'NR==1 {print $2}')
  if [ -z "${prefix}" ] ; then
    exit 1
  fi
  echo ${prefix}
}

# Migrate IP addresses from a network interface to a bridge
# Both IPv4 and IPv6 addresses are migrated properly
function migrate_ip_from_nic {
  src_nic=$1
  bridge_name=$2

  # Enabling explicit error handling
  set +e

  # Ensure the bridge interface is up
  ip link set ${bridge_name} up

  # Check if bridge already has global IP addresses (excluding link-local IPv6)
  bridge_has_addr=false
  bridge_ipv4=$(ip -4 addr show dev ${bridge_name} 2>/dev/null | grep inet)
  bridge_ipv6=$(ip -6 addr show dev ${bridge_name} 2>/dev/null | grep inet6 | grep -v "scope link")

  if [[ -n "$bridge_ipv4" ]] || [[ -n "$bridge_ipv6" ]]; then
    bridge_has_addr=true
    echo "Bridge '${bridge_name}' already has global IP configuration. Keeping as is..."
    set -e
    return 0
  fi

  # Store IPv4 addresses from source interface
  ipv4_addresses=()
  ipv4_data=$(ip -4 addr show dev ${src_nic} 2>/dev/null | grep inet)

  while read -r line; do
    if [[ -n "$line" ]]; then
      # Extract only the IP/prefix, broadcast and scope, removing interface name
      ip_prefix=$(echo "$line" | awk '{print $2}')
      broadcast=""
      if [[ "$line" =~ brd[[:space:]]([0-9.]+) ]]; then
        broadcast="brd ${BASH_REMATCH[1]}"
      fi
      scope=""
      if [[ "$line" =~ scope[[:space:]]([a-z]+) ]]; then
        scope="scope ${BASH_REMATCH[1]}"
      fi
      # Create clean config without interface name
      clean_config="${ip_prefix} ${broadcast} ${scope}"
      ipv4_addresses+=("$clean_config")
    fi
  done < <(echo "$ipv4_data")

  # Store global IPv6 addresses from source interface (excluding link-local)
  ipv6_addresses=()
  ipv6_data=$(ip -6 addr show dev ${src_nic} 2>/dev/null | grep inet6 | grep -v "scope link")

  while read -r line; do
    if [[ -n "$line" ]]; then
      # Extract only the IP/prefix and scope, removing interface name
      ip_prefix=$(echo "$line" | awk '{print $2}')
      scope=""
      if [[ "$line" =~ scope[[:space:]]([a-z]+) ]]; then
        scope="scope ${BASH_REMATCH[1]}"
      fi
      # Create clean config without interface name
      clean_config="${ip_prefix} ${scope}"
      ipv6_addresses+=("$clean_config")
    fi
  done < <(echo "$ipv6_data")

  # Check if we have any IPs to migrate
  if [[ ${#ipv4_addresses[@]} -eq 0 ]] && [[ ${#ipv6_addresses[@]} -eq 0 ]]; then
    echo "Interface ${src_nic} has no global IP addresses to migrate. Leaving as is."
    set -e
    return 0
  fi

  echo "Migrating ${#ipv4_addresses[@]} IPv4 and ${#ipv6_addresses[@]} IPv6 addresses from ${src_nic} to ${bridge_name}..."

  # Migration flag to track success/failure
  migration_failed=false

  # First add all IPv4 addresses to bridge
  for addr_config in "${ipv4_addresses[@]}"; do
    # Trim extra spaces
    addr_config=$(echo "$addr_config" | tr -s ' ' | sed 's/^ //;s/ $//')
    echo "Adding IPv4 config: $addr_config to ${bridge_name}"
    if ! ip addr add $addr_config dev ${bridge_name}; then
      echo "Error: Failed to add IPv4 configuration to ${bridge_name}"
      migration_failed=true
      break
    fi
  done

  # If IPv4 migration was successful, proceed with IPv6
  if [[ "$migration_failed" = false ]] && [[ ${#ipv6_addresses[@]} -gt 0 ]]; then
    for addr_config in "${ipv6_addresses[@]}"; do
      # Trim extra spaces
      addr_config=$(echo "$addr_config" | tr -s ' ' | sed 's/^ //;s/ $//')
      echo "Adding IPv6 config: $addr_config to ${bridge_name}"
      if ! ip addr add $addr_config dev ${bridge_name}; then
        echo "Error: Failed to add IPv6 configuration to ${bridge_name}"
        migration_failed=true
        break
      fi
    done
  fi

  # If all addresses were successfully added, flush source interface
  if [[ "$migration_failed" = false ]]; then
    echo "Successfully added all IP addresses to ${bridge_name}. Flushing source interface ${src_nic}..."

    # Give system a moment to process new config
    sleep 1

    # Flush source interface
    ip addr flush dev ${src_nic}

    # Verify system created routes
    echo "Verifying system created routes..."
    if ! ip route | grep -q "${bridge_name}"; then
      echo "Warning: No routes found for ${bridge_name}. This might cause connectivity issues."
    else
      echo "Routes for ${bridge_name} successfully created by system."
    fi
  else
    # Migration failed, remove any addresses added to bridge
    echo "IP migration failed. Cleaning up bridge ${bridge_name}..."

    # Clean up any IPs we might have added
    for addr_config in "${ipv4_addresses[@]}"; do
      ip_prefix=$(echo "$addr_config" | awk '{print $1}')
      ip addr del $ip_prefix dev ${bridge_name} 2>/dev/null || true
    done

    for addr_config in "${ipv6_addresses[@]}"; do
      ip_prefix=$(echo "$addr_config" | awk '{print $1}')
      ip addr del $ip_prefix dev ${bridge_name} 2>/dev/null || true
    done

    echo "Original interface ${src_nic} configuration preserved."
    exit 1
  fi

  set -e
}

function get_current_system_id {
  ovs-vsctl --if-exists get Open_vSwitch . external_ids:system-id | tr -d '"'
}

function get_stored_system_id {
  kubectl get node "$NODE_NAME" -o "jsonpath={.metadata.annotations.openstack-helm/ovn-system-id}"
}

function store_system_id() {
  local system_id=$1
  kubectl annotate node "$NODE_NAME" "$ANNOTATION_KEY=$system_id"
}

# Detect tunnel interface
tunnel_interface="{{- .Values.network.interface.tunnel -}}"
if [ -z "${tunnel_interface}" ] ; then
    # search for interface with tunnel network routing
    tunnel_network_cidr="{{- .Values.network.interface.tunnel_network_cidr -}}"
    if [ -z "${tunnel_network_cidr}" ] ; then
        tunnel_network_cidr="0/0"
    fi
    # If there is not tunnel network gateway, exit
    tunnel_interface=$(ip -4 route list ${tunnel_network_cidr} | awk -F 'dev' '{ print $2; exit }' \
        | awk '{ print $1 }') || exit 1
fi
ovs-vsctl set open . external_ids:ovn-encap-ip="$(get_ip_address_from_interface ${tunnel_interface})"

# Get the stored system-id from the Kubernetes node annotation
stored_system_id=$(get_stored_system_id)

# Get the current system-id set in OVS
current_system_id=$(get_current_system_id)

if [ -n "$stored_system_id" ] && [ "$stored_system_id" != "$current_system_id" ]; then
  # If the annotation exists and does not match the current system-id, set the system-id to the stored one
  ovs-vsctl set Open_vSwitch . external_ids:system-id="$stored_system_id"
elif [ -z "$current_system_id" ]; then
  # If no current system-id is set, generate a new one
  current_system_id=$(uuidgen)
  ovs-vsctl set Open_vSwitch . external_ids:system-id="$current_system_id"
  # Store the new system-id in the Kubernetes node annotation
  store_system_id "$current_system_id"
elif [ -z "$stored_system_id" ]; then
  # If there is no stored system-id, store the current one
  store_system_id "$current_system_id"
fi

# Configure OVN remote
{{- if empty .Values.conf.ovn_remote -}}
{{- $sb_svc_name := "ovn-ovsdb-sb" -}}
{{- $sb_svc := (tuple $sb_svc_name "internal" . | include "helm-toolkit.endpoints.hostname_fqdn_endpoint_lookup") -}}
{{- $sb_port := (tuple "ovn-ovsdb-sb" "internal" "ovsdb" . | include "helm-toolkit.endpoints.endpoint_port_lookup") -}}
{{- $sb_service_list := list -}}
{{- range $i := until (.Values.pod.replicas.ovn_ovsdb_sb | int) -}}
  {{- $sb_service_list = printf "tcp:%s-%d.%s:%s" $sb_svc_name $i $sb_svc $sb_port | append $sb_service_list -}}
{{- end }}

ovs-vsctl set open . external-ids:ovn-remote="{{ include "helm-toolkit.utils.joinListWithComma" $sb_service_list }}"
{{- else -}}
ovs-vsctl set open . external-ids:ovn-remote="{{ .Values.conf.ovn_remote }}"
{{- end }}

# Configure OVN values
ovs-vsctl set open . external-ids:rundir="/var/run/openvswitch"
ovs-vsctl set open . external-ids:ovn-encap-type="{{ .Values.conf.ovn_encap_type }}"
ovs-vsctl set open . external-ids:ovn-bridge="{{ .Values.conf.ovn_bridge }}"
ovs-vsctl set open . external-ids:ovn-bridge-mappings="{{ .Values.conf.ovn_bridge_mappings }}"

GW_ENABLED=$(cat /tmp/gw-enabled/gw-enabled)
if [[ ${GW_ENABLED} == {{ .Values.labels.ovn_controller_gw.node_selector_value }} ]]; then
  ovs-vsctl set open . external-ids:ovn-cms-options={{ .Values.conf.ovn_cms_options_gw_enabled }}
else
  ovs-vsctl set open . external-ids:ovn-cms-options={{ .Values.conf.ovn_cms_options }}
fi

{{ if .Values.conf.ovn_bridge_datapath_type -}}
ovs-vsctl set open . external-ids:ovn-bridge-datapath-type="{{ .Values.conf.ovn_bridge_datapath_type }}"
{{- end }}

# Configure hostname
{{- if .Values.pod.use_fqdn.compute }}
  ovs-vsctl set open . external-ids:hostname="$(hostname -f)"
{{- else }}
  ovs-vsctl set open . external-ids:hostname="$(hostname)"
{{- end }}

# Create bridges and create ports
# handle any bridge mappings
# /tmp/auto_bridge_add is one line json file: {"br-ex1":"eth1","br-ex2":"eth2"}
for bmap in `sed 's/[{}"]//g' /tmp/auto_bridge_add | tr "," "\n"`
do
  bridge=${bmap%:*}
  iface=${bmap#*:}
  ovs-vsctl --may-exist add-br $bridge -- set bridge $bridge protocols=OpenFlow13
  if [ -n "$iface" ] && [ "$iface" != "null" ] && ( ip link show $iface 1>/dev/null 2>&1 );
  then
    ovs-vsctl --may-exist add-port $bridge $iface
    migrate_ip_from_nic $iface $bridge
  fi
done