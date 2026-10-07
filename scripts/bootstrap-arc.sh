#!/bin/bash
# Azure-hosted Arc evaluation only; no credentials are written to cloud-init.
set -euo pipefail
umask 077

export DEBIAN_FRONTEND=noninteractive
export MSFT_ARC_TEST=true
readonly SUBSCRIPTION_ID='__SUBSCRIPTION_ID__'
readonly TENANT_ID='__TENANT_ID__'
readonly RESOURCE_GROUP='__RESOURCE_GROUP__'
readonly LOCATION='__LOCATION__'
readonly ARC_MACHINE_NAME='__ARC_MACHINE_NAME__'
readonly ARC_SCOPE_ID='__ARC_SCOPE_ID__'
readonly BOOTSTRAP_CLIENT_ID='__BOOTSTRAP_CLIENT_ID__'
readonly OWNER_TOKEN='__OWNER_TOKEN__'
readonly ENVIRONMENT_NAME='__ENVIRONMENT_NAME__'

trap 'logger -p local0.err -t retailtx-bootstrap "Bootstrap failed at line ${LINENO}"; touch /var/lib/retailtx/bootstrap-failed' ERR
install -d -m 0700 /var/lib/retailtx
apt-get update -qq
apt-get install -y -qq curl ca-certificates python3 iptables rsyslog

installer=$(mktemp)
trap 'rm -f "$installer"; unset token' EXIT
curl --fail --silent --show-error --location --retry 3 https://aka.ms/azcmagent -o "$installer"

systemctl set-environment MSFT_ARC_TEST=true
if ! grep -qx 'MSFT_ARC_TEST=true' /etc/environment; then
    printf '\nMSFT_ARC_TEST=true\n' >> /etc/environment
fi

# The short-lived bootstrap identity is used before Azure IMDS is blocked.
token=$(curl --fail --silent --show-error --retry 10 --retry-delay 15 \
    --header Metadata:true \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F&client_id=${BOOTSTRAP_CLIENT_ID}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
test -n "$token"

cat > /usr/local/sbin/retailtx-block-imds <<'BLOCK'
#!/bin/bash
set -euo pipefail
for address in 169.254.169.254 169.254.169.253; do
    if ! iptables -C OUTPUT -d "$address" -j REJECT 2>/dev/null; then
        iptables -I OUTPUT 1 -d "$address" -j REJECT
    fi
done
BLOCK
chmod 0700 /usr/local/sbin/retailtx-block-imds
cat > /etc/systemd/system/retailtx-block-imds.service <<'UNIT'
[Unit]
Description=Block Azure IMDS for the Arc evaluation host
Before=himdsd.service gcad.service extd.service
After=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/retailtx-block-imds
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl disable --now walinuxagent
systemctl enable --now retailtx-block-imds.service
systemctl disable --now ssh.service ssh.socket

# Linux installation checks IMDS even when the evaluation flag is set.
bash "$installer"

connected=false
for attempt in $(seq 1 12); do
    if azcmagent connect \
        --subscription-id "$SUBSCRIPTION_ID" \
        --tenant-id "$TENANT_ID" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --resource-name "$ARC_MACHINE_NAME" \
        --private-link-scope "$ARC_SCOPE_ID" \
        --access-token "$token" \
        --tags "demo=retailtx,environmentId=${ENVIRONMENT_NAME},ownerToken=${OWNER_TOKEN},managedBy=retailtx-stage0,site=dc1"; then
        connected=true
        break
    fi
    logger -p local0.warning -t retailtx-bootstrap "Arc onboarding attempt ${attempt} failed; retrying"
    sleep 20
done
unset token
if [[ "$connected" != true ]]; then
    echo "Arc registration did not succeed within the bounded retry window." >&2
    exit 1
fi

cat > /etc/systemd/system/retailtx-demo-worker.service <<'UNIT'
[Unit]
Description=RetailTx Stage 0 synthetic heartbeat fixture (not the posting application)
After=network-online.target

[Service]
Type=simple
User=nobody
ExecStart=/bin/sh -c 'while true; do logger -p local0.info -t retailtx-demo-worker "stage0 synthetic worker healthy"; sleep 30; done'
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now retailtx-demo-worker.service
rm -f /var/lib/retailtx/bootstrap-failed
touch /var/lib/retailtx/bootstrap-complete
logger -p local0.info -t retailtx-bootstrap "Arc evaluation bootstrap complete"
