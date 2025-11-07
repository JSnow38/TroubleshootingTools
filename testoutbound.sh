#!/usr/bin/env bash

# AKS Egress Test Script
# This script tests connectivity to critical Azure and Microsoft endpoints
# required for AKS cluster operation.

# Default values
CLUSTER_NAME=${1:-"XXXXXXXXXXXX"}  # First argument or default < change this
RG_NAME=${2:-"XXXXXXX"}                    # Second argument or default < change this
SUB=${3:-$(az account show --query id -o tsv)}  # Third argument or current sub < you can add you sub directly or login ahead of time

# Show usage if help is requested
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    echo "Usage: $0 [cluster_name] [resource_group] [subscription_id]"
    echo ""
    echo "Tests AKS cluster's connectivity to required endpoints."
    echo ""
    echo "Arguments:"
    echo "  cluster_name      Name of the AKS cluster (default: test-gen-purpose)"
    echo "  resource_group    Resource group of the cluster (default: aks)"
    echo "  subscription_id   Azure subscription ID (default: current subscription)"
    echo ""
    echo "Example:"
    echo "  $0                           # Use all defaults"
    echo "  $0 my-cluster my-rg          # Specify cluster and resource group"
    echo "  $0 my-cluster my-rg sub-id   # Specify all parameters"
    exit 0
fi

# Validate cluster exists
echo "Using:"
echo "  Cluster: $CLUSTER_NAME"
echo "  RG:      $RG_NAME"
echo "  Sub:     $SUB"
echo ""

# Set subscription if provided
[[ -n "$SUB" ]] && az account set --subscription "$SUB"

# Define the endpoints to check and build the cluster-check script
echo "Starting connectivity tests..."

endpoints=(
  "mcr.microsoft.com"           # Container registry
  "*.data.mcr.microsoft.com"    # Container registry data
  "management.azure.com"        # Azure Resource Manager
  "login.microsoftonline.com"
  "packages.microsoft.com"
  "acs-mirror.azureedge.net"
  "packages.aks.azure.com"
)
# Configuration
image="mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11"
timestamp=$(date +"%Y%m%d-%H%M%S")
ns="aks-egress-check-${timestamp}"  # More readable timestamp format

# Build a self-contained script that will run inside the pod to check endpoints
read -r -d '' CHECK_SCRIPT <<'CS'
#!/bin/bash
set -eo pipefail

# List of endpoints to check (will be replaced with literal array)
endpoints=(__ENDPOINTS__)

# Install tools
echo "Installing required packages..."
apt-get update -qq || true
apt-get install -y -qq dnsutils jq ca-certificates || { echo "Failed to install packages"; exit 1; }
echo "Packages installed successfully"

# Run DNS & HTTPS checks for each endpoint, expanding wildcards
echo "Starting endpoint checks..."
declare -A results
for host in "${endpoints[@]}"; do
  echo "Processing endpoint: $host"
  
  if [[ "$host" == \** ]]; then
    base="${host#*.}"
    candidates=("www.${base}" "api.${base}" "${base}")
    echo "Wildcard endpoint: trying ${candidates[*]}"
  else
    candidates=("$host")
    echo "Regular endpoint: $host"
  fi
  
  # Perform DNS checks
  ok_dns=0; ok_tls=0
  for h in "${candidates[@]}"; do
    echo "Testing DNS for: $h"
    dig_output=$(dig +short "$h")
    if [[ -n "$dig_output" ]]; then 
      ok_dns=1
      echo "✓ DNS resolved successfully for $h:"
      echo "$dig_output"
      break
    else
      echo "✗ DNS failed for $h"
    fi
  done
  
  # Perform HTTPS checks
  for h in "${candidates[@]}"; do
    echo "Testing HTTPS for: $h"
    if curl -vsSI --connect-timeout 5 --max-time 12 "https://${h}" 2>&1; then 
      ok_tls=1
      echo "✓ HTTPS connection successful for $h"
      break
    else
      echo "✗ HTTPS connection failed for $h"
    fi
  done
  
  echo "Final result for $host: DNS=$ok_dns, HTTPS=$ok_tls"
  json_result=$(jq -n --arg host "$host" --argjson dns "$ok_dns" --argjson https "$ok_tls" '{host:$host, dns_ok:($dns==1), https_ok:($https==1)}')
  results["$host"]="$json_result"
  echo "Stored result: ${results[$host]}"
  echo "---"
done

# Output JSON array of results
echo "Collecting final results..."
json_array="["
first=1
for k in "${!results[@]}"; do
  if [[ $first -eq 0 ]]; then 
    json_array+=","
  fi
  json_array+="${results[$k]}"
  first=0
done
json_array+="]"
echo "Final results in JSON format:"
echo "$json_array" | jq -r '.'
CS

# Insert endpoints into the check script
ENDPOINTS_LIT=""
for e in "${endpoints[@]}"; do ENDPOINTS_LIT="$ENDPOINTS_LIT '$e'"; done
CHECK_SCRIPT="${CHECK_SCRIPT//__ENDPOINTS__/$ENDPOINTS_LIT}"

# Build the remote payload that will set up the pod environment
read -r -d '' REMOTE_PAYLOAD <<'RP'
#!/bin/bash
set -eo pipefail

ns="__NS__"
image="__IMAGE__"
script="__SCRIPT__"

# Create namespace and configmap for script with base64 decoded content
kubectl create ns "$ns"
echo "$script" | base64 -d > /tmp/check.sh && chmod +x /tmp/check.sh && \
kubectl -n "$ns" create configmap check-script --from-file=run.sh=/tmp/check.sh && \
rm /tmp/check.sh

# Start pod with script mounted and make it executable
kubectl -n "$ns" run egress-check \
  --image="$image" \
  --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "checker",
        "image": "'"$image"'",
        "command": ["/bin/bash", "-c"],
        "args": ["/bin/bash /check/run.sh"],
        "volumeMounts": [{
          "name": "check-script",
          "mountPath": "/check"
        }]
      }],
      "volumes": [{
        "name": "check-script",
        "configMap": {
          "name": "check-script"
        }
      }]
    }
  }'

# Wait for pod, get logs, cleanup
echo "Waiting for test pod to become ready..."
kubectl -n "$ns" wait --for=condition=Ready pod/egress-check --timeout=300s || { echo "❌ Pod failed to become ready"; exit 1; }
echo "✓ Pod is ready, running tests..."
echo "───────────────────────────────────────────────"
sleep 30 # Give time for the script to complete
kubectl -n "$ns" logs -f egress-check || true
echo "───────────────────────────────────────────────"
status=$(kubectl -n "$ns" get pod egress-check -o json | jq -r .status.phase)
echo "Test pod status: $status"
# Cleanup
kubectl -n "$ns" delete pod egress-check --now --ignore-not-found
kubectl -n "$ns" delete configmap check-script --ignore-not-found
kubectl delete ns "$ns" --ignore-not-found
RP

# Insert values into the remote payload
REMOTE_PAYLOAD="${REMOTE_PAYLOAD/__NS__/$ns}"
REMOTE_PAYLOAD="${REMOTE_PAYLOAD/__IMAGE__/$image}"
# Base64-encode check script to avoid quoting issues
CHECK_SCRIPT_B64="$(printf '%s' "$CHECK_SCRIPT" | base64 -w0)"
REMOTE_PAYLOAD="${REMOTE_PAYLOAD/__SCRIPT__/$CHECK_SCRIPT_B64}"

# Send the payload to the cluster
REMOTE_B64="$(printf '%s' "$REMOTE_PAYLOAD" | base64 -w0)"
az aks command invoke \
  --resource-group "$RG_NAME" \
  --name "$CLUSTER_NAME" \
  --command "printf '%s' '$REMOTE_B64' | base64 -d | /bin/bash"
 
 
 