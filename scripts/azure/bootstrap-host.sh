#!/bin/bash
# Minimal host bootstrap; application releases arrive through owned guest operations.
set -euo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
readonly HOST_ROLE='__HOST_ROLE__'
readonly SUBSCRIPTION_ID='__SUBSCRIPTION_ID__'
readonly TENANT_ID='__TENANT_ID__'
readonly RESOURCE_GROUP='__RESOURCE_GROUP__'
readonly LOCATION='__LOCATION__'
readonly ARC_MACHINE_NAME='__ARC_MACHINE_NAME__'
readonly ARC_SCOPE_ID='__ARC_SCOPE_ID__'
readonly BOOTSTRAP_CLIENT_ID='__BOOTSTRAP_CLIENT_ID__'
readonly OWNER_TOKEN='__OWNER_TOKEN__'
readonly ENVIRONMENT_NAME='__ENVIRONMENT_NAME__'

install -d -m 0700 /var/lib/retailtx
trap 'logger -p local0.err -t retailtx-bootstrap "Host bootstrap failed at line ${LINENO}"; touch /var/lib/retailtx/bootstrap-failed' ERR
updated=false
for attempt in $(seq 1 12); do
    if apt-get -o Acquire::Retries=3 update -qq; then
        updated=true
        break
    fi
    logger -p local0.warning -t retailtx-bootstrap "Package index attempt ${attempt} failed"
    sleep 10
done
[[ "$updated" == true ]] || { echo 'Package indexes could not be refreshed.' >&2; exit 1; }
apt-get -o DPkg::Lock::Timeout=600 -o Acquire::Retries=3 install -y -qq \
    python3-venv curl ca-certificates openssl iptables rsyslog
id retailtx >/dev/null 2>&1 || useradd --system --home-dir /var/lib/retailtx-app --create-home retailtx
install -d -m 0750 -o root -g retailtx /etc/retailtx
install -d -m 0755 /opt/retailtx/releases
systemctl disable --now ssh.service ssh.socket

if [[ "$HOST_ROLE" == dc ]]; then
    apt-get -o DPkg::Lock::Timeout=600 -o Acquire::Retries=3 install -y -qq postgresql
    export MSFT_ARC_TEST=true
    systemctl set-environment MSFT_ARC_TEST=true
    grep -qx 'MSFT_ARC_TEST=true' /etc/environment || printf '\nMSFT_ARC_TEST=true\n' >> /etc/environment
    installer=$(mktemp)
    trap 'rm -f "$installer"; unset token' EXIT
    curl --fail --silent --show-error --location --retry 3 https://aka.ms/azcmagent -o "$installer"
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
    bash "$installer"
    connected=false
    for attempt in $(seq 1 12); do
        if azcmagent connect --subscription-id "$SUBSCRIPTION_ID" --tenant-id "$TENANT_ID" \
            --resource-group "$RESOURCE_GROUP" --location "$LOCATION" \
            --resource-name "$ARC_MACHINE_NAME" --private-link-scope "$ARC_SCOPE_ID" \
            --access-token "$token" \
            --tags "demo=retailtx,environmentId=${ENVIRONMENT_NAME},ownerToken=${OWNER_TOKEN},managedBy=retailtx,profile=azure-lite,site=dc1"; then
            connected=true
            break
        fi
        logger -p local0.warning -t retailtx-bootstrap "Arc onboarding attempt ${attempt} failed"
        sleep 20
    done
    unset token
    [[ "$connected" == true ]] || { echo 'Arc registration failed within the retry window.' >&2; exit 1; }
    usermod -a -G himds retailtx
elif [[ "$HOST_ROLE" != cloud ]]; then
    echo 'Unsupported host role.' >&2
    exit 1
fi
rm -f /var/lib/retailtx/bootstrap-failed
touch /var/lib/retailtx/bootstrap-complete
logger -p local0.info -t retailtx-bootstrap 'Host bootstrap complete; application installation pending'
