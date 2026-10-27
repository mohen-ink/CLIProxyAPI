#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPOSITORY="mohen-ink/CLIProxyAPI"
SERVICE="cliproxyapi.service"
INSTALL_DIR="$(pwd -P)"
BINARY="${INSTALL_DIR}/cli-proxy-api"
check_only=0
no_plugin=0
work_dir=""
backup=""
recovery_needed=0
replaced=0
was_active=0

log() { printf '%s\n' "$*"; }
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
用法：在 CLIProxyAPI 安装目录执行 bash update.sh [选项]

从 mohen-ink/CLIProxyAPI 的最新正式 Release 更新 ./cli-proxy-api。
使用当前用户的 cliproxyapi.service，请勿使用 sudo。
仅替换程序，保留 config.yaml、auths/ 和插件。
临时备份放在 .cliproxyapi-backups/；更新或回滚成功后删除，仅回滚失败时保留。

选项：
  --check       仅检查更新，不下载程序或操作服务
  --no-plugin   选择不支持动态插件的便携版（适用于 musl/旧系统）
  -h, --help    显示帮助

依赖：Bash 4+、curl、jq、tar、sha256sum、flock、systemctl 及常见 Linux 工具。
默认下载支持动态插件的 glibc 版本（要求 glibc 2.17+）。
HELP
}

cleanup() {
    local status=$? restore_stage="" keep_backup=0
    trap - EXIT INT TERM HUP
    if (( recovery_needed )); then
        status=1
        log '更新未完成，正在恢复原状态……' >&2
        if (( replaced )); then
            if systemctl --user stop "$SERVICE"; then
                restore_stage="${work_dir}/restore"
                if cp -p -- "$backup" "$restore_stage" && mv -f -- "$restore_stage" "$BINARY"; then
                    log '已恢复旧程序。' >&2
                    replaced=0
                else
                    keep_backup=1
                    log "错误：恢复旧程序失败，请手动从 ${backup} 恢复。" >&2
                fi
            else
                keep_backup=1
                log "错误：无法停止新服务，未执行回滚；旧程序备份：${backup}" >&2
            fi
        fi
        if (( ! replaced && was_active )); then
            if systemctl --user start "$SERVICE" && systemctl --user is-active --quiet "$SERVICE"; then
                log '原服务已重新启动。' >&2
            else
                keep_backup=1
                log "错误：原服务未恢复运行；备份保留在 ${backup}，请检查 journalctl --user -u ${SERVICE} -n 50。" >&2
            fi
        fi
    fi
    if [[ -n "$backup" ]] && (( ! keep_backup )); then
        if rm -f -- "$backup"; then
            rmdir -- "${backup%/*}" 2>/dev/null || true
        else
            status=1
            log "错误：清理临时备份失败，请手动删除：${backup}" >&2
        fi
    fi
    if [[ -n "$work_dir" ]]; then
        rm -rf -- "$work_dir"
    fi
    exit "$status"
}

read_version() {
    local output version
    output="$("$1" --help 2>&1)" || return 1
    version="$(printf '%s\n' "$output" | sed -n 's/^CLIProxyAPI Version: \([^,]*\),.*/\1/p')"
    [[ -n "$version" && "$version" != *$'\n'* ]] || return 1
    printf '%s\n' "${version#v}"
}

version_parts() {
    local value=${1#v}
    [[ "$value" =~ ^([0-9]{1,8})\.([0-9]{1,8})\.([0-9]{1,8})(-fork([0-9]{1,8}))?$ ]] || return 1
    printf '%d %d %d %d\n' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" \
        "$((10#${BASH_REMATCH[3]}))" "$((10#${BASH_REMATCH[5]:-0}))"
}

compare_versions() {
    local left_parts right_parts i
    local -a left right
    left_parts="$(version_parts "$1")" || return 1
    right_parts="$(version_parts "$2")" || return 1
    read -r -a left <<< "$left_parts"
    read -r -a right <<< "$right_parts"
    for i in 0 1 2 3; do
        if (( left[i] < right[i] )); then printf '%s\n' -1; return; fi
        if (( left[i] > right[i] )); then printf '%s\n' 1; return; fi
    done
    printf '0\n'
}

fetch() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --retry 3 --connect-timeout 15 --max-time 600 \
        --header 'Accept: application/vnd.github+json' --user-agent 'CLIProxyAPI-fork-updater' \
        --output "$2" "$1"
}

asset_url() {
    jq -er --arg name "$1" --arg prefix "https://github.com/${REPOSITORY}/releases/download/${tag}/" '
        [.assets[] | select(.name == $name and .state == "uploaded") | .browser_download_url]
        | if length == 1 then .[0] else error("missing or duplicate asset") end
        | select(startswith($prefix))
    ' "${work_dir}/release.json"
}

for arg in "$@"; do
    case "$arg" in
        --check) check_only=1 ;;
        --no-plugin) no_plugin=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "未知参数：${arg}" ;;
    esac
done

(( BASH_VERSINFO[0] >= 4 )) || fail '需要 Bash 4 或更高版本。'
[[ "$(uname -s)" == Linux ]] || fail '此脚本仅支持 Linux。'
case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) fail "不支持的系统架构：$(uname -m)（仅支持 amd64 和 arm64）。" ;;
esac
for tool in curl jq tar sha256sum flock systemctl mktemp cp mv chmod rm sed awk sleep; do
    command -v "$tool" >/dev/null 2>&1 || fail "缺少命令：${tool}，请先安装相应依赖。"
done
[[ -f "$BINARY" && -x "$BINARY" && ! -L "$BINARY" ]] || fail '当前目录必须包含可执行的普通文件 cli-proxy-api。'
[[ -w "$INSTALL_DIR" ]] || fail "安装目录不可写：${INSTALL_DIR}"
[[ ! -L "${INSTALL_DIR}/.cliproxyapi-update.lock" ]] || fail '更新锁不能是符号链接。'
exec 9> "${INSTALL_DIR}/.cliproxyapi-update.lock"
flock -n 9 || fail '另一个更新任务正在运行。'
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

load_state="$(systemctl --user show "$SERVICE" --property=LoadState --value)" || fail '无法访问当前用户的 systemd，请以运行服务的用户执行。'
[[ "$load_state" == loaded ]] || fail "用户级服务 ${SERVICE} 不存在或无法加载。"
current="$(read_version "$BINARY")" || fail '无法通过 ./cli-proxy-api --help 获取当前版本。'
version_parts "$current" >/dev/null || fail "无法识别当前版本：${current}；仅支持 X.Y.Z 和 X.Y.Z-forkN。"
work_dir="$(mktemp -d "${INSTALL_DIR}/.cliproxyapi-update.XXXXXXXX")"
log "安装目录：${INSTALL_DIR}"
log "系统架构：${arch}；当前版本：${current}"
log "正在检查 ${REPOSITORY} 的最新正式 Release……"
fetch "https://api.github.com/repos/${REPOSITORY}/releases/latest" "${work_dir}/release.json" || fail '获取 Release 失败，请检查网络或 GitHub API 限额。'
tag="$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | select(type == "string")' "${work_dir}/release.json")" || fail '无法解析最新正式 Release。'
latest=${tag#v}
comparison="$(compare_versions "$current" "$latest")" || fail "无法识别远端版本：${tag}"
log "最新版本：${tag}"
if [[ "$comparison" == 0 ]]; then
    log '当前已是最新版本，无需更新。'
    exit 0
fi
if [[ "$comparison" == 1 ]]; then
    log '当前版本高于远端最新正式版，不执行降级。'
    exit 0
fi
suffix=""
(( ! no_plugin )) || suffix="_no-plugin"
asset="CLIProxyAPI_${latest}_linux_${arch}${suffix}.tar.gz"
archive_url="$(asset_url "$asset")" || fail "Release 尚未提供完整的 ${asset}，请等待构建完成后重试；服务未停止。"
checksums_url="$(asset_url checksums.txt)" || fail 'Release 校验文件尚未就绪，服务未停止。'
log "发现更新：${current} → ${latest}"
log "目标构建：${asset}"
if (( check_only )); then
    log '仅检查模式，未下载或更新程序，未操作服务。'
    exit 0
fi

log '正在下载程序和 SHA-256 校验文件……'
fetch "$archive_url" "${work_dir}/${asset}" || fail '程序下载失败，服务未停止。'
fetch "$checksums_url" "${work_dir}/checksums.txt" || fail '校验文件下载失败，服务未停止。'
expected="$(awk -v name="$asset" 'NF == 2 && ($2 == name || $2 == "*" name) {print $1}' "${work_dir}/checksums.txt")"
[[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || fail '缺少唯一有效的 SHA-256 校验值，可能仍在构建中；服务未停止。'
actual="$(sha256sum "${work_dir}/${asset}")"
actual=${actual%% *}
[[ "${actual,,}" == "${expected,,}" ]] || fail '程序 SHA-256 校验失败，服务未停止。'

members="$(tar -tzf "${work_dir}/${asset}")" || fail '无法读取发布包。'
member=""
while IFS= read -r entry; do
    case "$entry" in
        /*|..|../*|*/../*|*/..) fail '发布包包含不安全路径，服务未停止。' ;;
        cli-proxy-api|./cli-proxy-api)
            [[ -z "$member" ]] || fail '发布包包含重复程序，服务未停止。'
            member=$entry
            ;;
    esac
done <<< "$members"
[[ -n "$member" ]] || fail '发布包不含 cli-proxy-api，服务未停止。'
metadata="$(tar -tvzf "${work_dir}/${asset}" -- "$member")" || fail '无法检查发布包程序类型。'
[[ "$metadata" == -* && "$metadata" != *$'\n'* ]] || fail '发布包程序不是唯一的普通文件，服务未停止。'
tar -xOzf "${work_dir}/${asset}" -- "$member" > "${work_dir}/cli-proxy-api" || fail '提取程序失败，服务未停止。'
chmod 755 "${work_dir}/cli-proxy-api"
staged_version="$(read_version "${work_dir}/cli-proxy-api")" || fail '新程序无法运行，可能与系统或架构不兼容；服务未停止。'
[[ "$staged_version" == "$latest" ]] || fail "程序版本 ${staged_version} 与 Release ${latest} 不一致，服务未停止。"
backup_dir="${INSTALL_DIR}/.cliproxyapi-backups"
[[ ! -L "$backup_dir" ]] || fail '备份目录不能是符号链接。'
mkdir -p -- "$backup_dir" || fail '创建备份目录失败，服务未停止。'
backup="$(mktemp "${backup_dir}/cli-proxy-api-${current}.XXXXXXXX")"
cp -p -- "$BINARY" "$backup" || fail '备份旧程序失败，服务未停止。'
log "临时备份位置：${backup}"
if systemctl --user is-active --quiet "$SERVICE"; then
    was_active=1
fi
log "正在停止用户级服务 ${SERVICE}……"
recovery_needed=1
systemctl --user stop "$SERVICE" || fail '停止服务失败。'
replaced=1
mv -f -- "${work_dir}/cli-proxy-api" "$BINARY" || fail '替换程序失败。'
log '正在启动服务并检查运行状态……'
systemctl --user start "$SERVICE" || fail '新服务启动失败。'
for ((attempt=0; attempt<5; attempt++)); do
    systemctl --user is-active --quiet "$SERVICE" || fail '新服务未能保持运行。'
    sleep 1
done
systemctl --user is-active --quiet "$SERVICE" || fail '新服务在启动观察期内退出。'
recovery_needed=0
log "更新成功：${latest}，${SERVICE} 正在运行。"