#!/usr/bin/env bash
# N5: cập nhật site, một vhost Nginx hoặc app; rollback khi thao tác/xác nhận lỗi.
set -Eeuo pipefail
usage() { printf 'Cách dùng: %s -t site|nginx|app -s <nguồn>\n  -h, --help: trợ giúp\n' "${0##*/}"; }
case ${1:-} in -h|--help) usage; exit 0;; esac
kind='' source_path=''
while getopts ':ht:s:' opt; do
    case $opt in
        h) usage; exit 0;;
        t) kind=$OPTARG;; s) source_path=$OPTARG;;
        *) usage >&2; exit 2;;
    esac
done
shift "$((OPTIND - 1))"
if (( $# != 0 )) || [[ -z "$source_path" ]]; then usage >&2; exit 2; fi
case $kind in site|nginx|app) ;; *) usage >&2; exit 2;; esac
if (( EUID != 0 )); then printf 'Dùng sudo\n' >&2; exit 2; fi
TOOL_NAME=deploy
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_root
require_commands flock rsync realpath nginx systemctl curl cp find
install -d -o root -g root -m 0750 "$LOG_DIR"
install -d -o root -g root -m 0711 "$DEPLOY_STATE"
exec 9>"$DEPLOY_STATE/deploy.lock"
if ! flock -n 9; then log_error 'Có deploy khác đang chạy'; exit 1; fi

pending=0
work='' target='' previous='' candidate=''
verify() {
    if ! wait_http "https://$STATUS_DOMAIN:$WEB_PORT/"; then return 1; fi
    if [[ "$kind" == app ]] || (( CHECK_APP )); then
        if ! wait_http "$APP_HEALTH_URL"; then return 1; fi
        if ! wait_http "https://$APP_DOMAIN:$WEB_PORT/health"; then return 1; fi
    fi
}
rollback() {
    log_warn "Rollback $kind từ $previous"
    case $kind in
        nginx)
            cp -a -- "$previous" "$target" || return 1
            nginx -t || return 1
            systemctl reload nginx || return 1
            ;;
        site)
            rsync -a --delete -- "$previous/" "$target/" || return 1
            nginx -t || return 1
            systemctl reload nginx || return 1
            ;;
        app)
            # Dừng để không phục vụ một cây code đang thay dở.
            systemctl stop labapp || return 1
            rsync -a --delete -- "$previous/" "$target/" || return 1
            systemctl restart labapp || return 1
            ;;
    esac
    verify
}
finish() {
    local rc=$?
    trap - ERR EXIT INT TERM
    set +e
    if (( pending )); then
        if rollback; then
            log_warn 'Rollback thành công; lần deploy vẫn được tính thất bại'
        else
            log_error "ROLLBACK THẤT BẠI. Giữ bản lưu ở $work; cần xử lý trực tiếp"
        fi
        rc=1
    fi
    if [[ -n "$work" ]]; then log_info "Bản lưu và staging: $work"; fi
    exit "$rc"
}
trap 'rc=$?; log_error "Deploy lỗi dòng $LINENO (rc=$rc)"; exit "$rc"' ERR
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

source_path=$(realpath -e -- "$source_path")
case $kind in
    site)
        case $STATUS_DIR in /var/www/status|/var/www/n5-practice) ;; *) log_error 'STATUS_DIR ngoài phạm vi cho phép'; exit 2;; esac
        if [[ ! -d "$source_path" || ! -f "$source_path/index.html" || -L "$STATUS_DIR" ]]; then
            log_error 'Site cần thư mục có index.html, đích không được là symlink'; exit 2
        fi
        target=$(realpath -e -- "$STATUS_DIR")
        ;;
    nginx)
        target=$(realpath -e -- "$NGINX_SITE_CONF")
        if [[ "$target" != /etc/nginx/* || ! -f "$source_path" || ! -f "$target" ]]; then
            log_error 'Cần file nguồn và vhost hiện có trong /etc/nginx'; exit 2
        fi
        ;;
    app)
        require_commands npm node runuser
        if [[ ! -d "$source_path" || ! -f "$source_path/package.json" || ! -f "$source_path/package-lock.json" ]]; then
            log_error 'N3 cần cung cấp package.json và package-lock.json'; exit 2
        fi
        if [[ -L /opt/app ]]; then log_error '/opt/app không được là symlink trong phiên bản này'; exit 2; fi
        target=$(realpath -e /opt/app)
        if [[ "$target" != /opt/app || ! -d "$target" ]]; then log_error 'Chưa có app nền tại /opt/app'; exit 2; fi
        if [[ $(systemctl show -p User --value labapp) != appsvc ]]; then
            log_error 'Service labapp phải chạy bằng appsvc'; exit 2
        fi
        ;;
esac
if [[ "$source_path" == "$target" || "$source_path" == "$target/"* || "$target" == "$source_path/"* ]]; then
    log_error 'Nguồn và đích không được trùng hoặc chứa nhau'; exit 2
fi
if ! nginx -t || ! systemctl is-active --quiet nginx || ! verify; then
    log_error 'Hệ thống nền chưa tốt; dừng trước khi thay đổi'; exit 1
fi
if [[ "$kind" == app ]] && ! systemctl is-active --quiet labapp; then
    log_error 'App nền chưa active'; exit 1
fi

work=$(mktemp -d "$DEPLOY_STATE/${kind}.XXXXXX")
previous="$work/previous"
candidate="$work/candidate"
if [[ "$kind" == nginx ]]; then
    cp -a -- "$target" "$previous"
    cp -- "$source_path" "$candidate"
else
    mkdir -- "$previous" "$candidate"
    rsync -a -- "$target/" "$previous/"
    rsync -a --exclude='.git/' --exclude='node_modules/' --exclude='.env*' --exclude='*.env' \
        -- "$source_path/" "$candidate/"
    if [[ -n $(find "$candidate" -type l -print -quit) ]]; then
        log_error 'Source không được chứa symlink; dependency sẽ cài riêng'; exit 2
    fi
    find "$candidate" -type d -exec chmod 0755 {} +
    find "$candidate" -type f -exec chmod 0644 {} +
    if [[ "$kind" == app ]]; then
        # Chỉ cho appsvc đi qua thư mục staging; bản cũ vẫn root-only.
        chgrp appsvc "$work"
        chmod 0750 "$work"
        chmod 0700 "$previous"
        chown -R appsvc:appsvc "$candidate"
        install -d -o appsvc -g appsvc -m 0700 "$work/npm-cache"
        if ! runuser -u appsvc -- env npm_config_cache="$work/npm-cache" \
            npm --prefix "$candidate" ci --omit=dev; then
            log_error 'Cài dependency lỗi; chưa thay app đang chạy'; exit 1
        fi
    else
        chown -R www-data:www-data "$candidate"
    fi
fi

# Bật cờ TRƯỚC lần thay đổi đầu tiên để EXIT trap xử lý cả lỗi giữa chừng.
pending=1
case $kind in
    nginx)
        install -o root -g root -m 0644 "$candidate" "$target"
        if ! nginx -t || ! systemctl reload nginx; then
            log_error 'Kiểm tra/reload Nginx thất bại'; exit 1
        fi
        ;;
    site)
        rsync -a --delete -- "$candidate/" "$target/"
        if ! nginx -t || ! systemctl reload nginx; then
            log_error 'Nginx không áp dụng được site'; exit 1
        fi
        ;;
    app)
        systemctl stop labapp
        rsync -a --delete -- "$candidate/" "$target/"
        if ! systemctl restart labapp; then log_error 'Restart app lỗi'; exit 1; fi
        ;;
esac
if ! verify; then log_error 'Xác nhận HTTP thất bại'; exit 1; fi
log_info "PASS: deploy $kind và xác nhận hoạt động"
pending=0
