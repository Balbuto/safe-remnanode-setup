#!/usr/bin/env bash
# No root, no network, no real Docker/UFW/Certbot, and no writes outside $tmp.
set -Eeuo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
entry=${REMNA_ENTRYPOINT:-"$repo/safe-remnanode-setup.sh"}
# shellcheck source=safe-remnanode-setup.sh
source "$entry"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() { if "$@"; then fail "unexpected success: $*"; fi; }
RN_APP_DIR="$tmp/remnanode"
RN_WWW_DIR="$RN_APP_DIR/www"
RN_XRAY_BIN_DIR="$RN_APP_DIR/bin"
RN_CERTS_DIR="$RN_APP_DIR/certs"
RN_LOG_DIR="$tmp/log"
RN_NGINX_LOG_DIR="$tmp/nginx-host"
RN_HOST_NGINX_ROTATE_FILE="$tmp/host-nginx-policy"
RN_LOGROTATE_FILE="$tmp/node-logrotate"
# shellcheck disable=SC2317 # Called from the sourced installer.
rn_enable_logrotate_scheduler() { :; }
logrotate() {
    [[ "$1 $2 $3" == '-d -s /dev/null' && -f "$4" ]] || return 1
    if [[ -n "${LOGROTATE_BIN:-}" ]]; then "$LOGROTATE_BIN" "$@"; fi
}
RN_LOG_FILE="$tmp/install.log"
trace="$tmp/trace"
mkdir -p "$RN_APP_DIR" "$RN_CERTS_DIR" "$RN_LOG_DIR" "$tmp/shared-webroot"
rn_load_node_state 2> "$tmp/fresh-state.stderr"
[[ "$RN_XRAY_VERSION_CHOICE" == built-in && ! -s "$tmp/fresh-state.stderr" ]] || fail 'fresh state reported a missing Compose file or loaded a legacy version'
printf x > "$RN_CERTS_DIR/snakeoil.pem"
printf x > "$RN_CERTS_DIR/snakeoil.key"
printf 'untouched\n' > "$tmp/shared-webroot/index.html"

help=$(bash "$entry" --help)
[[ "$help" == *install-cli* ]] || fail 'help not available'
rn_valid_ipv4 192.0.2.10
expect_failure rn_valid_ipv4 192.0.2.999
rn_valid_domain node.example.co.uk
expect_failure rn_valid_domain 'invalid domain'
rn_valid_port 65535
expect_failure rn_valid_port 65536
rn_public_range_ok 2222 8443:8500
expect_failure rn_public_range_ok 2222 2220:2240
expect_failure rn_public_range_ok 2222 3000:4000:5000
rn_render_page_template dark
[[ $(cat "$tmp/shared-webroot/index.html") == untouched ]] || fail 'shared webroot changed'
[[ $(stat -c %a "$RN_WWW_DIR/index.html") == 644 ]] || fail 'wrong webroot permissions'
grep -q 'name="remnanode-template" content="dark"' "$RN_WWW_DIR/index.html" || fail 'selected theme not applied'
page_hash=$(sha256sum "$RN_WWW_DIR/index.html")
expect_failure rn_render_page_template '../unknown'
[[ $(sha256sum "$RN_WWW_DIR/index.html") == "$page_hash" ]] || fail 'invalid template replaced the page'
[[ $(rn_pick_page_template <<< 2) == minimal ]] || fail 'manual template selection'
case $(rn_pick_page_template <<< 4) in status|minimal|dark) ;; *) fail 'random theme not bundled' ;; esac
echo 'PASS: help, validation, and isolated webroot with local themes'

# Model UFW dry-run output and persisted exact matches without touching the host.
ufw_state="$tmp/ufw-rules"
: > "$ufw_state"
ufw() {
    printf '%s\n' "$*" >> "$trace"
    case "$*" in
        status*) printf 'Status: %s\nDefault: deny (incoming)\n' "${ufw_status:-active}" ;;
        '--dry-run allow '*)
            shift
            if [[ "${ufw_families_partial:-0}" == 1 ]]; then
                printf 'Rules updated (v6)\nSkipping adding existing rule\n'
            elif grep -Fx -- "$*" "$ufw_state" >/dev/null; then
                printf 'Skipping adding existing rule\n'
                if [[ "$2" != from ]]; then printf 'Skipping adding existing rule (v6)\n'; fi
            else
                printf 'Rules updated\n'
            fi
            ;;
        'show added')
            printf 'Added user rules (see %s for running firewall):\n' "'ufw status'"
            sed 's/^/ufw /' "$ufw_state"
            ;;
        'prepend allow '*)
            [[ "${ufw_allow_fail:-0}" == 0 ]] || return 1
            [[ "${ufw_forget_rule:-0}" == 0 ]] || return 0
            shift
            grep -Fxq -- "$*" "$ufw_state" || printf '%s\n' "$*" >> "$ufw_state"
            ;;
        '--force enable') ufw_status=active ;;
        'allow '*)
            [[ "${ufw_allow_fail:-0}" == 0 ]] || return 1
            printf '%s\n' "$*" >> "$ufw_state"
            ;;
        *) fail "unexpected UFW operation: $*" ;;
    esac
}
ufw_status=inactive
expect_failure rn_configure_firewall 2222 192.0.2.10
[[ $(wc -l < "$trace") == 1 ]] || fail 'attempt to change inactive firewall'
ufw_status=active
ufw_allow_fail=1
expect_failure rn_configure_firewall 2222 192.0.2.10
[[ $(wc -l < "$trace") == 4 ]] || fail 'continued after UFW error'
ufw_allow_fail=0
printf '8443\n8443:8443\n443\n80\n8443\n' > "$RN_APP_DIR/.xray_ports"
rn_configure_firewall 2222 192.0.2.10 8443 443 80 8443:8443
[[ $(cat "$RN_APP_DIR/.xray_ports") == $'8443\n80' ]] || fail 'saved port list not normalized'
[[ $(wc -l < "$ufw_state") == 7 ]] || fail 'duplicate base/custom rules on initial run'
[[ $(grep -c '^allow 80/tcp ' "$ufw_state") == 1 && $(grep -c '^allow 80/udp ' "$ufw_state") == 1 ]] || fail 'bad handling of optional UDP/80'
old_ports_inode=$(stat -c %i "$RN_APP_DIR/.xray_ports")
: > "$trace"
rn_configure_firewall 2222 192.0.2.10 8443:8443 443 80
if grep '^allow ' "$trace" >/dev/null; then fail 'repeat install wrote existing UFW rules'; fi
[[ $(stat -c %i "$RN_APP_DIR/.xray_ports") == "$old_ports_inode" ]] || fail 'repeat install rewrote unchanged ports'
ufw_families_partial=1
: > "$trace"
rn_ufw_allow 8443/tcp comment 'Xray Custom Port TCP'
grep -q '^allow 8443/tcp ' "$trace" || fail 'missing address-family rule was skipped'
ufw_families_partial=0
rm -f -- "$RN_APP_DIR/.xray_ports"
echo 'PASS: repeated UFW install performs no writes; duplicate ports and partial-family state handled'
(
    # shellcheck disable=SC2317 # Called indirectly from the sourced installer.
    cls() { :; }
    # shellcheck disable=SC2317 # Called indirectly from the sourced installer.
    rn_install_dependencies() { printf 'unexpected apt\n' >> "$trace"; return 1; }
    # shellcheck disable=SC2317 # Called indirectly from the sourced installer.
    rn_prepare_latest_xray() { printf 'unexpected download\n' >> "$trace"; return 1; }
    SSH_CONNECTION=
    # shellcheck disable=SC2317 # Mock reached from the sourced installer.
    ss() { return 0; }
    : > "$trace"
    ufw_status=inactive
    expect_failure rn_initial_setup </dev/null
    [[ $(cat "$trace") == 'status verbose' ]] || fail 'unconfirmed SSH port did not stop installation early'
)
echo 'PASS: inactive UFW never enables or changes packages with no confirmed SSH listener'

(
    RN_UFW_DEFAULTS_FILE="$tmp/ufw-defaults"
    printf 'IPV6=yes\nDEFAULT_INPUT_POLICY="DROP"\n' > "$RN_UFW_DEFAULTS_FILE"
    SSH_CONNECTION=
    ss() {
        [[ "$*" == '-Hltnp' ]] || return 1
        printf '%s\n' 'LISTEN 0 128 0.0.0.0:24222 0.0.0.0:* users:(("sshd",pid=37,fd=5))' \
            'LISTEN 0 128 [::]:24222 [::]:* users:(("sshd",pid=37,fd=6))' \
            'LISTEN 0 128 0.0.0.0:44222 0.0.0.0:* users:(("systemd",pid=1,fd=10))' \
            'LISTEN 0 128 127.0.0.1:22 0.0.0.0:* users:(("sshd",pid=38,fd=5))'
    }
    [[ $(rn_ssh_port_for_ufw </dev/null) == 24222 ]] || fail 'did not detect custom SSH port from process'
    SSH_CONNECTION='2001:db8::20 48222 2001:db8::33 44222'
    [[ $(rn_ssh_port_for_ufw </dev/null) == 44222 ]] || fail 'did not prefer the current socket-activated SSH session'
    : > "$trace"; : > "$ufw_state"
    ufw_status=inactive
    rn_prepare_ufw_initial </dev/null
    [[ $(cat "$trace") == $'status verbose\nshow added\nprepend allow 44222/tcp comment SSH (initial setup)\nshow added\n--force enable\nstatus verbose' ]] || fail 'bootstrap did not stage SSH before activation'
    : > "$trace"
    rn_prepare_ufw_initial </dev/null
    [[ $(cat "$trace") == 'status verbose' ]] || fail 'active firewall was modified'
    ufw_status=inactive
    : > "$trace"; : > "$ufw_state"
    printf 'IPV6=no\nDEFAULT_INPUT_POLICY="DROP"\n' > "$RN_UFW_DEFAULTS_FILE"
    expect_failure rn_prepare_ufw_initial </dev/null
    [[ $(cat "$trace") == 'status verbose' ]] || fail 'IPv6 session attempted unsupported activation'
    printf 'IPV6=yes\nDEFAULT_INPUT_POLICY="ACCEPT"\n' > "$RN_UFW_DEFAULTS_FILE"
    : > "$trace"
    expect_failure rn_prepare_ufw_initial </dev/null
    [[ $(cat "$trace") == 'status verbose' ]] || fail 'unexpected UFW default policy was modified'
    printf 'IPV6=yes\nDEFAULT_INPUT_POLICY="DROP"\n' > "$RN_UFW_DEFAULTS_FILE"
    printf 'deny 44222/tcp\n' > "$ufw_state"
    : > "$trace"
    expect_failure rn_prepare_ufw_initial </dev/null
    [[ $(cat "$trace") == $'status verbose\nshow added' ]] || fail 'saved restrictive firewall rules were overridden'
    : > "$trace"; : > "$ufw_state"
    ufw_allow_fail=1
    expect_failure rn_prepare_ufw_initial </dev/null
    if grep -Fq -- '--force enable' "$trace"; then fail 'enabled firewall after SSH rule error'; fi
    ufw_allow_fail=0
    ufw_forget_rule=1
    expect_failure rn_prepare_ufw_initial </dev/null
    if grep -Fq -- '--force enable' "$trace"; then fail 'enabled firewall with SSH rule absent'; fi
    ufw_forget_rule=0
    touch "$RN_APP_DIR/docker-compose.yml"
    : > "$trace"
    expect_failure rn_prepare_ufw_initial </dev/null
    [[ $(cat "$trace") == 'status verbose' ]] || fail 'existing deployment reached firewall bootstrap'
    rm -f "$RN_APP_DIR/docker-compose.yml"
    SSH_CONNECTION=
    ss() {
        printf '%s\n' 'LISTEN 0 128 0.0.0.0:44222 0.0.0.0:* users:(("systemd",pid=1,fd=10))'
    }
    [[ $(rn_ssh_port_for_ufw <<< 44222) == 44222 ]] || fail 'manual socket-activated SSH port was not accepted'
    expect_failure rn_ssh_port_for_ufw <<< 22

    # Pretend the ufw package is absent until its mocked installation.
    ufw_installed=0
    # shellcheck disable=SC2317 # Mock reached from the sourced installer.
    command() {
        if [[ "$*" == '-v ufw' && "$ufw_installed" == 0 ]]; then return 1; fi
        builtin command "$@"
    }
    # shellcheck disable=SC2317 # Mock reached from the sourced installer.
    apt_update() { printf 'apt_update\n' >> "$trace"; }
    # shellcheck disable=SC2317 # Mock reached from the sourced installer.
    apt_install() { [[ "$*" == ufw ]] || return 1; printf 'apt_install ufw\n' >> "$trace"; ufw_installed=1; }
    : > "$trace"
    rn_prepare_ufw_initial <<< 44222
    [[ $(head -n 2 "$trace") == $'apt_update\napt_install ufw' ]] || fail 'missing UFW not installed before use'
    grep -Fxq -- '--force enable' "$trace" || fail 'newly installed firewall not enabled'
)
echo 'PASS: fresh UFW is staged before enable, handles custom/IPv6 SSH, and fails safely'

# VLESS TCP and Hy2 UDP must be separate firewall specifications.
(
    : > "$trace"
    : > "$ufw_state"
    expect_failure rn_configure_combined_firewall 2222 192.0.2.10 8443 8443 443
    expect_failure rn_configure_combined_firewall 2222 192.0.2.10 8443 2053 2222
    expect_failure rn_configure_combined_firewall 2222 192.0.2.10 8443 61000 443
    [[ ! -s "$trace" ]] || fail 'invalid combined ports changed UFW'
    rn_configure_combined_firewall 2222 192.0.2.10 8443 2053 8443
    grep -Fxq 'allow 8443/tcp comment VLESS TLS TCP' "$ufw_state" || fail 'missing TLS rule'
    grep -Fxq 'allow 2053/tcp comment VLESS xHTTP TLS TCP' "$ufw_state" || fail 'missing xHTTP rule'
    grep -Fxq 'allow 8443/udp comment Hysteria2 UDP' "$ufw_state" || fail 'missing exact Hy2 UDP rule'
    [[ $(wc -l < "$ufw_state") == 4 ]] || fail 'combined mode adds unnecessary firewall rules'
    : > "$trace"
    rn_configure_combined_firewall 2222 192.0.2.10 8443 2053 8443
    if grep -q '^allow ' "$trace"; then fail 'combined mode reapplied existing rules'; fi
    : > "$trace"
    : > "$ufw_state"
    expect_failure rn_configure_combined_firewall 2222 192.0.2.10 8443 443/udp 443
    expect_failure rn_configure_combined_firewall 2222 192.0.2.10 8443 1500/quic 443
    [[ ! -s "$trace" ]] || fail 'invalid xHTTP UDP plan touched UFW'
    rn_configure_combined_firewall 2222 192.0.2.10 8443 8443/udp 443
    grep -Fxq 'allow 8443/udp comment VLESS xHTTP TLS UDP' "$ufw_state" || fail 'missing xHTTP UDP rule'
    grep -Fxq 'allow 443/udp comment Hysteria2 UDP' "$ufw_state" || fail 'missing Hy2 with xHTTP/UDP'
    [[ $(wc -l < "$ufw_state") == 4 ]] || fail 'combined UDP mode adds unnecessary firewall rules'
)
echo 'PASS: combined UFW uses only requested TCP/UDP ports and rejects collisions'

# Wildcards cover direct children, not the apex or deeper descendants.
check_acme_names() {
    local hostname="$1" zone="$2"
    shift 2
    local -a san_args=()
    rn_build_acme_names "$hostname" "$zone" san_args || fail 'valid ACME names rejected'
    [[ "${san_args[*]}" == "$*" ]] || fail "unexpected ACME names: ${san_args[*]}"
}
check_acme_names spb.example.com '' -d spb.example.com
check_acme_names Spb.Example.Com example.com -d example.com -d '*.example.com'
check_acme_names example.com example.com -d example.com -d '*.example.com'
check_acme_names edge.spb.example.com example.com -d example.com -d '*.example.com' -d edge.spb.example.com
unused_names=()
expect_failure rn_build_acme_names badexample.com example.com unused_names
[[ ${#unused_names[@]} -eq 0 ]] || fail 'invalid zone changed arguments'
echo 'PASS: ACME exact, apex, single-label wildcard, deep descendant, and invalid zone'

# Mock an occupied HTTP-01 port. Certbot and service management must not run.
ss() { printf 'LISTEN 0 128 *:80 *:*\n'; }
certbot() { printf 'unexpected certbot\n' >> "$trace"; return 1; }
systemctl() { printf 'unexpected systemctl\n' >> "$trace"; return 1; }
# shellcheck disable=SC2317 # Mock reached from the sourced installer.
docker() { printf 'unexpected docker\n' >> "$trace"; return 1; }
: > "$trace"
expect_failure rn_issue_ssl_certificates_multi node.example.co.uk <<< $'2\noperator@example.co.uk'
[[ ! -s "$trace" ]] || fail 'busy port touched Certbot or another service'
[[ $(cat "$RN_WWW_DIR/index.html") == *'Сайт временно недоступен'* ]] || fail 'HTML missing'
echo 'PASS: occupied HTTP-01 port does not stop services'

(
    # shellcheck disable=SC2317 # Mock reached from the sourced installer.
    ss() { return 0; }
    : > "$trace"
    port80_plan=$(rn_format_transport_plan 80 2053 443)
    expect_failure rn_issue_ssl_certificates_multi node.example.co.uk combined "$port80_plan" <<< $'2\noperator@example.co.uk'
    [[ ! -s "$trace" ]] || fail 'planned VLESS TCP/80 still attempted HTTP-01'
)
echo 'PASS: HTTP-01 rejects a planned VLESS TCP/80 conflict'

# Compose mock checks the staged files and simulates failed deployment/rollback.
docker() {
    [[ $1 == compose ]] || fail 'not a compose invocation'
    printf '%s\n' "$*" >> "$trace"
    case "$*" in
        *'config --quiet')
            [[ -f "$3/.env" && -f "$3/nginx.conf" && -f "$3/docker-compose.yml" ]] || return 2
            grep -q 'labels: { io.safe-remnanode.nginx-config:' "$3/docker-compose.yml" || return 2
            [[ "${stage_fail:-0}" == 0 ]] || return 1
            if [[ -n "${COMPOSE_BIN:-}" ]]; then shift; "$COMPOSE_BIN" "$@"; fi
            ;;
        *'up -d --wait --wait-timeout 60')
            if [[ "${deploy_fail:-0}" == 1 ]] && grep -q '^SECRET_KEY=new-key$' .env; then return 1; fi
            ;;
        *) fail "unexpected Docker operation: $*" ;;
    esac
}
: > "$trace"
rn_deploy_compose reality 2222 old-key node.example.co.uk
secret_mode=$(stat -c %a "$RN_APP_DIR/.env")
[[ "$secret_mode" == 600 ]] || fail 'secret file not private'
old_hash=$(sha256sum "$RN_APP_DIR/docker-compose.yml")
old_inode=$(stat -c %i "$RN_APP_DIR/nginx.conf")
rn_deploy_compose reality 2222 old-key node.example.co.uk
[[ $(stat -c %i "$RN_APP_DIR/nginx.conf") == "$old_inode" ]] || fail 'repeated deploy replaces an unchanged file'
: > "$trace"
stage_fail=1
expect_failure rn_deploy_compose reality 2222 new-key node2.example.co.uk
[[ $(wc -l < "$trace") == 1 ]] || fail 'invalid config was applied'
grep -qx 'SECRET_KEY=old-key' "$RN_APP_DIR/.env" || fail 'invalid config replaced the previous key'
stage_fail=0
deploy_fail=1
: > "$trace"
RN_DECOY_DOMAIN=example.co.uk
expect_failure rn_deploy_compose reality 2222 new-key node2.example.co.uk
[[ $(cat "$RN_APP_DIR/.node_domain") == node.example.co.uk ]] || fail 'domain not rolled back'
[[ $(cat "$RN_APP_DIR/.decoy_domain") == github.com ]] || fail 'decoy state not rolled back'
[[ $(sha256sum "$RN_APP_DIR/docker-compose.yml") == "$old_hash" ]] || fail 'Compose config not rolled back'
[[ $(grep -c '^compose up ' "$trace") == 2 ]] || fail 'did not reapply previous Compose config'
echo 'PASS: Compose validates before apply, preserves unchanged files and rolls back a failed update'

# First-run Reality explicitly requests an SNI and keeps it for subsequent deploys.
test_fresh_reality() {
    local RN_APP_DIR="$tmp/fresh-reality"
    local RN_WWW_DIR="$RN_APP_DIR/www"
    local RN_XRAY_BIN_DIR="$RN_APP_DIR/bin"
    local RN_CERTS_DIR="$RN_APP_DIR/certs"
    local ufw_state="$tmp/reality-ufw"
    : > "$ufw_state"
    : > "$trace"
    deploy_fail=0
    for invalid_sni in '' 'https://cover.example.org' 'cover.example.org:443' '*.example.org' '192.0.2.18' '2001:db8::18'; do
        expect_failure rn_valid_reality_sni "$invalid_sni"
    done
    # shellcheck disable=SC2317 # Mocks reached from the sourced installer.
    cls() { :; }
    # shellcheck disable=SC2317
    rn_install_dependencies() { :; }
    # shellcheck disable=SC2317
    rn_prepare_latest_xray() { :; }
    # shellcheck disable=SC2317
    register_global_commands() { :; }
    # shellcheck disable=SC2317
    rn_issue_ssl_certificates_multi() { fail 'Reality unexpectedly requested ACME'; }
    wizard_start=$'n\n192.0.2.31\nnew-node.example.org\n\nmock-secret\n\n1\n'
    expect_failure rn_initial_setup <<< "$wizard_start"
    [[ ! -s "$ufw_state" && ! -e "$RN_APP_DIR/docker-compose.yml" ]] || fail 'Reality deployed without an SNI'
    : > "$trace"
    rn_initial_setup <<< "${wizard_start}"$'https://invalid.example.org\nCover.Example.ORG\n\n2\n\n'
    grep -Fxq 'reality' "$RN_APP_DIR/.protocol" || fail 'wrong first-run protocol'
    grep -Fxq 'cover.example.org' "$RN_APP_DIR/.decoy_domain" || fail 'SNI not normalized/persisted'
    grep -Eq '^[[:space:]]+server_name cover[.]example[.]org;' "$RN_APP_DIR/nginx.conf" || fail 'chosen SNI did not reach nginx'
    grep -Fxq 'new-node.example.org' "$RN_APP_DIR/.node_domain" || fail 'SNI replaced node DNS name'
    rn_load_node_state
    [[ "$RN_DECOY_DOMAIN" == cover.example.org ]] || fail 'saved Reality SNI not reloaded'
}
(test_fresh_reality)
echo 'PASS: fresh Reality requires a DNS SNI, writes it to nginx, and remembers it separately'

# Latest uses only the stable endpoint and never falls back after a failure.
(
    : > "$trace"
    curl() {
        [[ "${*: -1}" == 'https://api.github.com/repos/XTLS/Xray-core/releases/latest' ]] || return 2
        if [[ "${api_fail:-0}" == 1 ]]; then return 1; fi
        printf '%s\n' "${release_json:-}"
    }
    rn_download_xray_core() {
        printf '%s\n' "$1" >> "$trace"
        [[ "${download_fail:-0}" == 0 ]]
    }
    RN_XRAY_VERSION_CHOICE=legacy
    release_json='{"tag_name":"v99.1.2","draft":false,"prerelease":true}'
    expect_failure rn_prepare_latest_xray
    [[ ! -s "$trace" && "$RN_XRAY_VERSION_CHOICE" == legacy ]] || fail 'prerelease accepted as stable'
    api_fail=1
    expect_failure rn_prepare_latest_xray
    [[ ! -s "$trace" && "$RN_XRAY_VERSION_CHOICE" == legacy ]] || fail 'changed version on API failure'
    api_fail=0
    release_json='{"tag_name":"v99.1.1","draft":false,"prerelease":false}'
    download_fail=1
    expect_failure rn_prepare_latest_xray
    [[ "$RN_XRAY_VERSION_CHOICE" == legacy ]] || fail 'changed version on download failure'
    download_fail=0
    rn_prepare_latest_xray
    [[ "$RN_XRAY_VERSION_CHOICE" == v99.1.1 && $(tail -n 1 "$trace") == v99.1.1 ]] || fail 'wrong version downloaded'
    printf 'placeholder\n' | install -m 0755 -D /dev/stdin "$RN_XRAY_BIN_DIR/v99.1.1/xray"
    deploy_fail=0
    rn_deploy_compose reality 2222 old-key node.example.co.uk
    grep -Fq -- '/bin/v99.1.1/xray:/usr/local/bin/xray:ro' "$RN_APP_DIR/docker-compose.yml" || fail 'selected binary not mounted'
)
echo 'PASS: latest stable Xray resolution, failure handling, and exact binary mount'

# Bind logs and the selected certificate under stable, domain-based container paths.
(
    deploy_fail=0
    cert_domain=node.example.co.uk
    cert_dir="$RN_CERTS_DIR/managed/$cert_domain"
    mkdir -p "$cert_dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=example.co.uk' \
        -addext 'subjectAltName=DNS:*.example.co.uk' -keyout "$cert_dir/privkey.pem" -out "$cert_dir/fullchain.pem" >/dev/null 2>&1
    printf 'existing log\n' > "$RN_LOG_DIR/access.log"
    rn_deploy_compose xhttp 2222 old-key "$cert_domain"
    grep -Fq 'image: nginx:1.31' "$RN_APP_DIR/docker-compose.yml" || fail 'unexpected nginx image'
    current_compose=$(sha256sum "$RN_APP_DIR/docker-compose.yml")
    cp "$cert_dir/privkey.pem" "$tmp/correct-key.pem"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "$cert_dir/privkey.pem" 2>/dev/null
    expect_failure rn_deploy_compose xhttp 2222 old-key "$cert_domain"
    [[ $(sha256sum "$RN_APP_DIR/docker-compose.yml") == "$current_compose" ]] || fail 'wrong key changed live Compose'
    mv "$tmp/correct-key.pem" "$cert_dir/privkey.pem"
    cp "$cert_dir/privkey.pem" "$RN_CERTS_DIR/privkey.pem"
    cp "$cert_dir/fullchain.pem" "$RN_CERTS_DIR/fullchain.pem"
    expect_failure rn_deploy_compose tls 2222 old-key node.other.example
    [[ $(sha256sum "$RN_APP_DIR/docker-compose.yml") == "$current_compose" ]] || fail 'wrong certificate hostname changed live Compose'
    rm -f -- "$RN_CERTS_DIR/privkey.pem" "$RN_CERTS_DIR/fullchain.pem"
    grep -Fq -- "$RN_LOG_DIR:/var/log/remnanode" "$RN_APP_DIR/docker-compose.yml" || fail 'missing Remnanode logs mount'
    grep -Fq -- "$RN_NGINX_LOG_DIR:/var/log/nginx" "$RN_APP_DIR/docker-compose.yml" || fail 'missing nginx logs mount'
    grep -Fq -- "$RN_LOG_DIR/xray:/var/log/xray" "$RN_APP_DIR/docker-compose.yml" || fail 'missing s6 logs mount'
    [[ $(grep -Fc -- "$cert_dir:/etc/letsencrypt/live/$cert_domain:ro" "$RN_APP_DIR/docker-compose.yml") == 2 ]] || fail 'wrong certificate directory bind'
    grep -Fq -- "$cert_dir:/etc/xray/certs:ro" "$RN_APP_DIR/docker-compose.yml" || fail 'legacy Xray certificate alias was removed'
    grep -Fq 'access_log /var/log/nginx/access.log;' "$RN_APP_DIR/nginx.conf" || fail 'missing nginx access_log'
    grep -Fq 'error_log /var/log/nginx/error.log warn;' "$RN_APP_DIR/nginx.conf" || fail 'missing nginx error_log'
    if grep -Fq ssl_certificate "$RN_APP_DIR/nginx.conf"; then fail 'xHTTP nginx unexpectedly terminates TLS'; fi
    [[ $(cat "$RN_LOG_DIR/access.log") == 'existing log' ]] || fail 'existing log truncated'
    [[ $(stat -c %a "$RN_NGINX_LOG_DIR/error.log") == 640 ]] || fail 'incorrect log permissions'
    grep -Fq 'docker kill --signal=USR1 remnawave-nginx' "$RN_LOGROTATE_FILE" || fail 'nginx logs are not reopened'
    grep -Fq "$RN_LOG_DIR/access.log $RN_LOG_DIR/error.log" "$RN_LOGROTATE_FILE" || fail 'missing Xray rotation paths'
    touch "$RN_HOST_NGINX_ROTATE_FILE"
    RN_DECOY_DOMAIN="$cert_domain"
    rn_deploy_compose reality 2222 old-key "$cert_domain"
    grep -Fq -- "$RN_LOG_DIR/nginx:/var/log/nginx" "$RN_APP_DIR/docker-compose.yml" || fail 'host nginx directory conflict'
    grep -Fq "ssl_certificate \"/etc/letsencrypt/live/$cert_domain/fullchain.pem\";" "$RN_APP_DIR/nginx.conf" || fail 'nginx not using matching wildcard'
    rm -f -- "$RN_HOST_NGINX_ROTATE_FILE"
    printf 'example.co.uk\n' > "$cert_dir/.wildcard_zone"
    rn_deploy_compose xhttp 2222 old-key "$cert_domain"
    [[ $(grep -Fc -- "$cert_dir:/etc/letsencrypt/live/example.co.uk:ro" "$RN_APP_DIR/docker-compose.yml") == 2 ]] || fail 'missing default wildcard zone alias'
    rm -f -- "$cert_dir/.wildcard_zone"
    BACKUP_DIR="$tmp/backups"
    rn_apply_node_logging example.co.uk
    [[ $(cat "$RN_APP_DIR/.cert_path_domain") == example.co.uk ]] || fail 'explicit certificate alias not saved'
    rn_deploy_compose xhttp 2222 old-key "$cert_domain"
    [[ $(grep -Fc -- "$cert_dir:/etc/letsencrypt/live/example.co.uk:ro" "$RN_APP_DIR/docker-compose.yml") == 2 ]] || fail 'certificate alias lost during redeploy'
    expect_failure rn_deploy_compose xhttp 2222 old-key "$cert_domain" status https://example.co.uk
    expect_failure rn_deploy_compose xhttp 2222 old-key "$cert_domain" status other.example
)
echo 'PASS: file logs, rotation config, dynamic TLS paths, wildcard alias persistence and xHTTP socket behavior'

# Combined mode keeps certificates and port state across deployment and rollback.
(
    deploy_fail=0
    cert_domain=node.example.co.uk
    cert_dir="$RN_CERTS_DIR/managed/$cert_domain"
    initial_plan=$(rn_format_transport_plan 8443 2053 443)
    rn_deploy_compose combined 2222 old-key "$cert_domain" status example.co.uk "$initial_plan"
    [[ $(cat "$RN_APP_DIR/.transport_ports") == "$initial_plan" ]] || fail 'combined port plan not saved'
    grep -Fq -- "$cert_dir:/etc/letsencrypt/live/example.co.uk:ro" "$RN_APP_DIR/docker-compose.yml" || fail 'combined mode lost certificate alias'
    if grep -Fq ssl_certificate "$RN_APP_DIR/nginx.conf"; then fail 'combined nginx unexpectedly terminates TLS'; fi
    rn_deploy_compose combined 2222 old-key "$cert_domain"
    deploy_fail=1
    new_plan=$(rn_format_transport_plan 9443 2053 443)
    expect_failure rn_deploy_compose combined 2222 new-key "$cert_domain" status '' "$new_plan"
    [[ $(cat "$RN_APP_DIR/.transport_ports") == "$initial_plan" ]] || fail 'failed combined deployment did not roll back saved ports'
    printf '192.0.2.10\n' > "$RN_APP_DIR/.panel_ip"
    before=$(sha256sum "$RN_APP_DIR/docker-compose.yml" "$RN_APP_DIR/nginx.conf")
    : > "$trace"
    rn_set_existing_transport_ports 8443 2053 443
    [[ $(sha256sum "$RN_APP_DIR/docker-compose.yml" "$RN_APP_DIR/nginx.conf") == "$before" ]] || fail 'port adoption modified Compose or nginx'
    if grep -q '^compose ' "$trace"; then fail 'port adoption restarted a container'; fi
    : > "$trace"
    rn_set_existing_transport_ports 8443 2053 443
    if grep -Eq '^(allow|compose) ' "$trace"; then fail 'port adoption was not idempotent'; fi
    ss() {
        case "$*" in
            '-Hltnp sport = :8443'|'-Hltnp sport = :2053'|'-Hlunp sport = :443') printf '%s\n' 'users:(("rw-core",pid=11,fd=10))' ;;
            *) return 1 ;;
        esac
    }
    rn_check_transport_ports
    rn_set_existing_transport_ports 8443 1500/udp 443
    grep -Fxq 'XHTTP_UDP=1500' "$RN_APP_DIR/.transport_ports" || fail 'missing persisted xHTTP UDP plan'
    ss() {
        case "$*" in
            '-Hltnp sport = :8443'|'-Hlunp sport = :1500'|'-Hlunp sport = :443') printf '%s\n' 'users:(("rw-core",pid=11,fd=10))' ;;
            *) return 1 ;;
        esac
    }
    rn_check_transport_ports
    # shellcheck disable=SC2317 # Mock reached from the sourced installer.
    ss() { return 0; }
    expect_failure rn_check_transport_ports
    # shellcheck disable=SC2317 # Mock reached from the sourced installer.
    ss() { printf '%s\n' 'users:(("nginx",pid=11,fd=10))'; }
    expect_failure rn_check_transport_ports
)
echo 'PASS: combined mode preserves port plan and TLS; existing deployment not restarted by port setup'

# A broken archive or digest must not publish a custom build.
ARCH_XRAY=64
curl() {
    local out='' url="${*: -1}"
    while (($#)); do
        if [[ $1 == -o ]]; then out="$2"; break; fi
        shift
    done
    if [[ "$url" == *.dgst ]]; then
        printf 'SHA256= %064d\n' 0 > "$out"
    else
        printf 'not an archive\n' > "$out"
    fi
}
expect_failure rn_download_xray_core v26.1.1
[[ ! -e "$RN_XRAY_BIN_DIR/v26.1.1" ]] || fail 'published unchecked binary'
echo 'PASS: wrong Xray digest stops publication'

# Uninstall must not touch the admin's firewall or shared assets.
RN_LOGROTATE_FILE="$tmp/node-logrotate"
RN_RENEW_HOOK="$tmp/renew-hook"
printf 'node logrotate\n' > "$RN_LOGROTATE_FILE"
printf '#!/bin/bash\n# safe-remnanode managed certificate hook\n' > "$RN_RENEW_HOOK"
printf 'admin rule\n' > "$tmp/ufw.conf"
ufw() { fail 'uninstall touched UFW'; }
cls() { :; }
pause_prompt() { :; }
docker() { [[ "$*" == 'compose down' && "${down_fail:-0}" == 0 ]]; }
down_fail=1
expect_failure rn_uninstall_and_rollback <<< y
[[ -f "$RN_APP_DIR/.env" && -f "$RN_RENEW_HOOK" ]] || fail 'failed down removed working configuration'
down_fail=0
rn_uninstall_and_rollback <<< y
[[ ! -d "$RN_APP_DIR" && ! -e "$RN_RENEW_HOOK" ]] || fail 'managed files remain after successful uninstall'
[[ $(cat "$tmp/shared-webroot/index.html") == untouched ]] || fail 'uninstall touched shared webroot'
[[ $(cat "$tmp/ufw.conf") == 'admin rule' ]] || fail 'uninstall touched admin rules'
echo 'PASS: uninstall keeps configuration on failed down and preserves shared resources'

# Validate the exact payload delivered in the standalone installer, not a working tree.
(
    bundle="$tmp/rkn-bundle"
    rejected="$tmp/rkn-corrupt"
    mkdir "$bundle" "$rejected"
    if [[ -z "$REMNA_SOURCE_ROOT" ]]; then
        mkdir "$tmp/standalone-only"
        cp -- "$entry" "$tmp/standalone-only/setup.sh"
        (cd "$tmp/standalone-only" && bash -euc 'source ./setup.sh; rkn_unpack_bundle "$1"' bash "$bundle")
    else
        rkn_unpack_bundle "$bundle"
    fi
    diff -qr "$repo/vendor/rkn-watcher" "$bundle" || fail 'RKN payload differs from the vendored source'
    [[ $(< "$bundle/VERSION") == "$RKN_VERSION" ]] || fail 'bundle version mismatch'
    [[ $(find "$bundle/lib" -type f -name '*.sh' | wc -l) == 8 ]] || fail 'incomplete RKN modules'
    [[ $("$bundle/rkn-watcher.sh" --version) == "RKN Watcher $RKN_VERSION" ]] || fail 'bundle entry did not load modules'
    "$bundle/installer.sh" --help >/dev/null
    for file in "$bundle"/*.sh "$bundle"/lib/*.sh; do bash -n "$file"; done
    PYTHONPYCACHEPREFIX="$tmp/pycache" python3 -m py_compile "$bundle/config_tool.py" "$bundle/geoip_apply.py" \
        "$repo/tools/refresh-rkn-bundle.py" "$repo/tools/build_standalone.py"
    # Exercise actual helper and lib copy from the upstream staging layout.
    case "$bundle" in "$tmp/"*) ;; *) fail 'unexpected RKN staging path';; esac
    bash -euc '
        RKN_ROOT=$1; source "$1/lib/config.sh"; rkn_load_modules
        INSTALL_DIR=$2 CONFIG_DIR=$2/config DATA_DIR=$2/data LOG_DIR=$2/log
        CACHE_DIR=$2/cache STATE_DIR=$2/state SNAPSHOT_DIR=$2/snapshots LOCK_DIR=$2/locks
        COUNTRY_CACHE_DIR=$2/country LIST_CACHE_DIR=$2/lists ACTION_LOG=$2/actions.log
        CONFIG_TOOL=$2/config_tool.py GEOIP_APPLY_SCRIPT=$2/geoip_apply.py
        copy_helper_scripts
    ' bash "$bundle" "$tmp/rkn-copy"
    cmp "$bundle/config_tool.py" "$tmp/rkn-copy/config_tool.py"
    cmp "$bundle/lib/cli.sh" "$tmp/rkn-copy/lib/cli.sh"
    if [[ -n "$REMNA_SOURCE_ROOT" ]]; then
        broken_vendor="$tmp/bad-vendor"
        cp -a -- "$repo/vendor/rkn-watcher" "$broken_vendor"
        printf '\n# corrupt fixture\n' >> "$broken_vendor/lib/cli.sh"
        expect_failure rkn_copy_vendor_bundle "$broken_vendor" "$rejected"
    else
        RKN_BUNDLE_SHA256=$(printf '%064d' 0)
        expect_failure rkn_unpack_bundle "$rejected"
    fi
    [[ -z $(find "$rejected" -mindepth 1 -print -quit) ]] || fail 'damaged bundle was extracted'
)
echo 'PASS: pinned RKN bundle loads, stages all helpers and rejects corruption'

(
    RKN_INSTALL_DIR="$tmp/rkn-migration/opt"
    RKN_MAIN_SCRIPT="$RKN_INSTALL_DIR/rkn-watcher.sh"
    RKN_CONFIG_DIR="$tmp/rkn-migration/etc"
    RKN_BIN_PATH="$tmp/rkn-migration/launcher"
    RKN_BACKUP_ROOT="$tmp/rkn-migration/backups"
    unset RKN_ASSUME_YES
    export trace
    : > "$trace"
    # shellcheck disable=SC2317 # Test only: no installed dependencies or root required.
    check_root() { :; }
    # shellcheck disable=SC2317
    rkn_unpack_bundle() {
        cat > "$1/installer.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${RKN_ASSUME_YES:-0}" >> "$trace"
EOF
        chmod 700 "$1/installer.sh"
    }
    rkn_install_or_upgrade
    [[ $(< "$trace") == 'install 0' ]] || fail 'fresh Watcher install unexpectedly skipped setup'
    mkdir -p "$RKN_INSTALL_DIR" "$RKN_CONFIG_DIR"
    printf 'AUTO_UPDATE="n"\n' > "$RKN_CONFIG_DIR/settings.conf"
    cat > "$RKN_MAIN_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$trace"
EOF
    chmod 700 "$RKN_MAIN_SCRIPT"
    ln -s "$RKN_MAIN_SCRIPT" "$RKN_BIN_PATH"
    rkn_install_or_upgrade
    grep -Fxq 'install 1' "$trace" || fail 'migration did not select preserve mode'
    tar -tf "$RKN_BACKUP_ROOT"/safe-rkn-watcher.*/files.tgz > "$tmp/rkn-backup-contents"
    grep -Fq "${RKN_CONFIG_DIR#/}/settings.conf" "$tmp/rkn-backup-contents" || fail 'RKN config missing from backup'
    [[ $(< "$RKN_CONFIG_DIR/settings.conf") == 'AUTO_UPDATE="n"' ]] || fail 'RKN settings modified by adapter'
    rkn_run_installed apply --dry-run
    grep -Fxq 'apply --dry-run' "$trace" || fail 'installed CLI did not receive flags'
    ln -sf /bin/true "$RKN_BIN_PATH"
    expect_failure rkn_install_or_upgrade
    [[ $(readlink "$RKN_BIN_PATH") == /bin/true ]] || fail 'unrelated launcher overwritten'
)
echo 'PASS: RKN migration backs up existing settings, forwards flags and preserves unrelated launchers'

if [[ -n "$REMNA_SOURCE_ROOT" ]]; then
    [[ $(remna_cli_payload) == "$repo/safe-remnanode-setup.sh" ]] || fail 'module loader would install itself as the global CLI'
    echo 'PASS: modular entry registers the standalone CLI, not the source loader'
fi
