#!/usr/bin/env bash
# ------------------------------------------------------------------
# <ten_script>.sh — <mô tả ngắn script làm gì>
# Tác giả: <tên> | Ngày: <yyyy-mm-dd>
# ------------------------------------------------------------------
# Mẫu chuẩn của nhóm: copy file này khi viết script mới.
# Yêu cầu đề: set -euo pipefail, trap ERR, --help, getopts, log rõ ràng,
# shellcheck sạch.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Nạp thư viện chung (log, load config, alert)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
    cat <<EOF
Cách dùng: ${SCRIPT_NAME} [-h] [-v] [-o <tuỳ chọn>]

  -h    Hiển thị trợ giúp
  -v    In chi tiết
  -o    Ví dụ một tuỳ chọn có giá trị
EOF
}

# Bắt lỗi: không bỏ qua thầm lặng
on_error() {
    local exit_code=$? line=$1
    log_error "${SCRIPT_NAME} lỗi ở dòng ${line} (mã ${exit_code})"
    exit "${exit_code}"
}
on_exit() {
    log_info "${SCRIPT_NAME} kết thúc"
}
trap 'on_error ${LINENO}' ERR
trap on_exit EXIT

VERBOSE=0
OPTION=""

while getopts ":hvo:" opt; do
    case "${opt}" in
        h) usage; exit 0 ;;
        v) VERBOSE=1 ;;
        o) OPTION="${OPTARG}" ;;
        :) echo "Thiếu giá trị cho -${OPTARG}" >&2; usage; exit 2 ;;
        *) echo "Tuỳ chọn không hợp lệ: -${OPTARG}" >&2; usage; exit 2 ;;
    esac
done

main() {
    log_info "${SCRIPT_NAME} bắt đầu (verbose=${VERBOSE}, option='${OPTION}')"
    # TODO: logic chính ở đây
}

main "$@"
