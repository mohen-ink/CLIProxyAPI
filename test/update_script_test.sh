#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
for tool in jq tar sha256sum bash; do
    command -v "$tool" >/dev/null || { printf 'Missing test dependency: %s\n' "$tool" >&2; exit 1; }
done
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
REAL_MV="$(command -v mv)"
REAL_CP="$(command -v cp)"
export REAL_MV REAL_CP
mkdir -p "$TEST_ROOT/mock-bin"

cat > "$TEST_ROOT/mock-bin/uname" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    -s) printf '%s\n' "${MOCK_OS:-Linux}" ;;
    -m) printf '%s\n' "$MOCK_ARCH" ;;
    *) exit 1 ;;
esac
MOCK
cat > "$TEST_ROOT/mock-bin/flock" <<'MOCK'
#!/usr/bin/env bash
[[ "${MOCK_LOCKED:-0}" == 0 ]]
MOCK
cat > "$TEST_ROOT/mock-bin/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$TEST_ROOT/mock-bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
out=""
url=""
while (($#)); do
    case "$1" in
        --output) out=$2; shift 2 ;;
        --proto|--proto-redir|--retry|--connect-timeout|--max-time|--header|--user-agent) shift 2 ;;
        --*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\n' "$url" >> "$CASE_DIR/downloads.log"
[[ "$url" == https://api.github.com/repos/mohen-ink/CLIProxyAPI/releases/latest || "$url" == https://github.com/mohen-ink/CLIProxyAPI/releases/download/* ]] || exit 90
if [[ "$url" == */releases/latest ]]; then
    [[ "$SCENARIO" != api_failure ]] || exit 22
    "$REAL_CP" "$CASE_DIR/release.json" "$out"
else
    [[ "$SCENARIO" != download_failure ]] || exit 22
    "$REAL_CP" "$CASE_DIR/assets/${url##*/}" "$out"
fi
MOCK
cat > "$TEST_ROOT/mock-bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$CASE_DIR/systemctl.log"
[[ "$1" == --user && " $* " == *" cliproxyapi.service "* ]] || exit 91
shift
case "$1" in
    show) printf '%s\n' "${MOCK_LOAD_STATE:-loaded}" ;;
    stop)
        [[ "$SCENARIO" != stop_failure ]] || exit 1
        if [[ "$SCENARIO" == rollback_stop_failure && -f "$CASE_DIR/start-failed" ]]; then exit 1; fi
        printf 'inactive\n' > "$CASE_DIR/service.state"
        ;;
    start)
        version="$($CASE_DIR/install\ dir/cli-proxy-api --help)"
        if [[ "$version" == *"Version: 8.0.44-fork1,"* && ( "$SCENARIO" == start_failure || "$SCENARIO" == rollback_stop_failure ) ]]; then
            : > "$CASE_DIR/start-failed"
            exit 1
        fi
        printf 'active\n' > "$CASE_DIR/service.state"
        ;;
    is-active)
        if [[ "$SCENARIO" == crash_after_start && -f "$CASE_DIR/replaced" ]]; then
            : > "$CASE_DIR/start-failed"
            exit 1
        fi
        [[ "$(< "$CASE_DIR/service.state")" == active ]]
        ;;
    *) exit 92 ;;
esac
MOCK
cat > "$TEST_ROOT/mock-bin/mv" <<'MOCK'
#!/usr/bin/env bash
set -eu
source_path="${@: -2:1}"
target="${@: -1}"
if [[ "$source_path" == */.cliproxyapi-update.*/cli-proxy-api && "$target" == */cli-proxy-api ]]; then
    [[ "$SCENARIO" != replace_failure ]] || exit 1
    : > "$CASE_DIR/replaced"
fi
if [[ "$source_path" == */restore && "$SCENARIO" == rollback_replace_failure ]]; then exit 1; fi
"$REAL_MV" "$@"
if [[ "$source_path" == */restore ]]; then rm -f "$CASE_DIR/replaced"; fi
MOCK
chmod +x "$TEST_ROOT/mock-bin/"*
export PATH="$TEST_ROOT/mock-bin:$PATH"

make_binary() {
    local destination=$1 version=$2
    printf '#!/usr/bin/env bash\n[[ "$1" == --help ]] || exit 99\nprintf "CLIProxyAPI Version: %s, Commit: mock, BuiltAt: mock\\n"\n' "$version" > "$destination"
    chmod +x "$destination"
}

setup_case() {
    SCENARIO=$1
    CASE_DIR="$TEST_ROOT/$SCENARIO"
    export SCENARIO CASE_DIR
    export MOCK_ARCH=x86_64 MOCK_OS=Linux MOCK_LOCKED=0 MOCK_LOAD_STATE=loaded
    mkdir -p "$CASE_DIR/install dir/auths" "$CASE_DIR/assets" "$CASE_DIR/archive"
    make_binary "$CASE_DIR/install dir/cli-proxy-api" 8.0.28-fork1
    make_binary "$CASE_DIR/archive/cli-proxy-api" 8.0.44-fork1
    printf 'keep-config\n' > "$CASE_DIR/install dir/config.yaml"
    printf 'keep-auth\n' > "$CASE_DIR/install dir/auths/test.json"
    printf 'must-not-install\n' > "$CASE_DIR/archive/config.yaml"
    printf 'active\n' > "$CASE_DIR/service.state"
    : > "$CASE_DIR/systemctl.log"
    : > "$CASE_DIR/downloads.log"
    for arch in amd64 aarch64; do
        for suffix in '' _no-plugin; do
            asset="CLIProxyAPI_8.0.44-fork1_linux_${arch}${suffix}.tar.gz"
            tar -czf "$CASE_DIR/assets/$asset" -C "$CASE_DIR/archive" cli-proxy-api config.yaml
        done
    done
    refresh_checksums
    jq -n '{draft:false,prerelease:false,tag_name:"v8.0.44-fork1",assets:(["amd64","aarch64"] | map(. as $a | ["","_no-plugin"] | map("CLIProxyAPI_8.0.44-fork1_linux_" + $a + . + ".tar.gz")) | add | . + ["checksums.txt"] | map({name:.,state:"uploaded",browser_download_url:("https://github.com/mohen-ink/CLIProxyAPI/releases/download/v8.0.44-fork1/" + .)}))}' > "$CASE_DIR/release.json"
}

refresh_checksums() {
    (cd "$CASE_DIR/assets" && sha256sum ./*.tar.gz | sed -e 's|  ./|  |' -e 's| \*./| *|' > checksums.txt)
}

expect() {
    if ! "$@"; then
        printf 'FAIL [%s]: %s\n' "$SCENARIO" "$*" >&2
        cat "$CASE_DIR/output.log" >&2
        exit 1
    fi
}

assert_untouched() {
    [[ "$(< "$CASE_DIR/install dir/config.yaml")" == keep-config && "$(< "$CASE_DIR/install dir/auths/test.json")" == keep-auth ]]
}

assert_old() { [[ "$("$CASE_DIR/install dir/cli-proxy-api" --help)" == *'Version: 8.0.28-fork1,'* ]]; }
assert_new() { [[ "$("$CASE_DIR/install dir/cli-proxy-api" --help)" == *'Version: 8.0.44-fork1,'* ]]; }
assert_active() { [[ "$(< "$CASE_DIR/service.state")" == active ]]; }
assert_not_stopped() { [[ "$(< "$CASE_DIR/systemctl.log")" != *'--user stop '* ]]; }
assert_backup() {
    local -a backups root_backups
    shopt -s nullglob
    root_backups=("$CASE_DIR/install dir/"cli-proxy-api.backup-*)
    ((${#root_backups[@]} == 0)) || return 1
    backups=("$CASE_DIR/install dir/.cliproxyapi-backups/"*)
    if [[ "$SCENARIO" == rollback_stop_failure ]]; then
        ((${#backups[@]} == 1)) && [[ "$("${backups[0]}" --help)" == *'Version: 8.0.28-fork1,'* ]]
    else
        ((${#backups[@]} == 0)) && [[ ! -d "$CASE_DIR/install dir/.cliproxyapi-backups" ]]
    fi
}
assert_cleaned() {
    local -a leftovers
    shopt -s nullglob
    leftovers=("$CASE_DIR/install dir/".cliproxyapi-update.*/)
    ((${#leftovers[@]} == 0))
}

run_update() {
    local expected_status=$1 actual=0
    shift
    (cd "$CASE_DIR/install dir" && bash "$ROOT/update.sh" "$@") > "$CASE_DIR/output.log" 2>&1 || actual=$?
    if [[ "$expected_status" == success ]]; then
        expect test "$actual" -eq 0
    else
        expect test "$actual" -ne 0
    fi
    expect assert_untouched
    expect assert_cleaned
    expect assert_backup
}

for scenario in success arm64 arm_alias amd_alias portable check_only same_version newer_local numeric_newer fork_revision base_version unsupported_arch unsupported_os missing_service locked api_failure download_failure missing_asset missing_checksums missing_checksum_entry bad_checksum duplicate_checksum wrong_binary_version unsafe_archive missing_binary duplicate_binary stop_failure replace_failure start_failure crash_after_start rollback_stop_failure; do
    [[ $# == 0 || " $* " == *" $scenario "* ]] || continue
    setup_case "$scenario"
    expected=failure
    args=()
    case "$scenario" in
        success) expected=success ;;
        arm64) MOCK_ARCH=aarch64; expected=success ;;
        arm_alias) MOCK_ARCH=arm64; expected=success ;;
        amd_alias) MOCK_ARCH=amd64; expected=success ;;
        portable) args=(--no-plugin); expected=success ;;
        check_only) args=(--check); expected=success ;;
        same_version) make_binary "$CASE_DIR/install dir/cli-proxy-api" 8.0.44-fork1; expected=success ;;
        newer_local) make_binary "$CASE_DIR/install dir/cli-proxy-api" 8.0.45-fork1; expected=success ;;
        numeric_newer) make_binary "$CASE_DIR/install dir/cli-proxy-api" 8.0.100-fork1; expected=success ;;
        fork_revision) make_binary "$CASE_DIR/install dir/cli-proxy-api" 8.0.44-fork2; expected=success ;;
        base_version) make_binary "$CASE_DIR/install dir/cli-proxy-api" 8.0.44; expected=success ;;
        unsupported_arch) MOCK_ARCH=armv7l ;;
        unsupported_os) MOCK_OS=Darwin ;;
        missing_service) MOCK_LOAD_STATE=not-found ;;
        locked) MOCK_LOCKED=1 ;;
        api_failure|download_failure|stop_failure|replace_failure|start_failure|crash_after_start|rollback_stop_failure) ;;
        missing_asset) jq '.assets |= map(select(.name != "CLIProxyAPI_8.0.44-fork1_linux_amd64.tar.gz"))' "$CASE_DIR/release.json" > "$CASE_DIR/changed.json"; "$REAL_MV" "$CASE_DIR/changed.json" "$CASE_DIR/release.json" ;;
        missing_checksums) jq '.assets |= map(select(.name != "checksums.txt"))' "$CASE_DIR/release.json" > "$CASE_DIR/changed.json"; "$REAL_MV" "$CASE_DIR/changed.json" "$CASE_DIR/release.json" ;;
        missing_checksum_entry) printf 'incomplete\n' > "$CASE_DIR/assets/checksums.txt" ;;
        bad_checksum) printf '%064d  CLIProxyAPI_8.0.44-fork1_linux_amd64.tar.gz\n' 0 > "$CASE_DIR/assets/checksums.txt" ;;
        duplicate_checksum) "$REAL_CP" "$CASE_DIR/assets/checksums.txt" "$CASE_DIR/copy.txt"; cat "$CASE_DIR/copy.txt" >> "$CASE_DIR/assets/checksums.txt" ;;
        wrong_binary_version) make_binary "$CASE_DIR/archive/cli-proxy-api" 8.0.43-fork1; tar -czf "$CASE_DIR/assets/CLIProxyAPI_8.0.44-fork1_linux_amd64.tar.gz" -C "$CASE_DIR/archive" cli-proxy-api; refresh_checksums ;;
        unsafe_archive) tar -czf "$CASE_DIR/assets/CLIProxyAPI_8.0.44-fork1_linux_amd64.tar.gz" --transform='s|cli-proxy-api|../cli-proxy-api|' -C "$CASE_DIR/archive" cli-proxy-api; refresh_checksums ;;
        missing_binary) tar -czf "$CASE_DIR/assets/CLIProxyAPI_8.0.44-fork1_linux_amd64.tar.gz" --transform='s|cli-proxy-api|renamed|' -C "$CASE_DIR/archive" cli-proxy-api; refresh_checksums ;;
        duplicate_binary) tar -czf "$CASE_DIR/assets/CLIProxyAPI_8.0.44-fork1_linux_amd64.tar.gz" -C "$CASE_DIR/archive" cli-proxy-api cli-proxy-api; refresh_checksums ;;
    esac
    run_update "$expected" "${args[@]}"
    case "$scenario" in
        success|arm64|arm_alias|amd_alias|portable|base_version) expect assert_new; expect assert_active; [[ "$scenario" == base_version ]] || expect assert_backup ;;
        check_only|same_version|newer_local|numeric_newer|fork_revision) expect assert_not_stopped ;;
        replace_failure|start_failure|crash_after_start) expect assert_old; expect assert_active; expect assert_backup ;;
        rollback_stop_failure) expect assert_new; expect assert_backup ;;
        stop_failure) expect assert_old; expect assert_active; expect assert_backup ;;
        *) expect assert_old; expect assert_not_stopped ;;
    esac
    case "$scenario" in
        arm64|arm_alias) expect test -f "$CASE_DIR/replaced"; expect test "$(< "$CASE_DIR/downloads.log")" != "${CASE_DIR}/unused"; [[ "$(< "$CASE_DIR/downloads.log")" == *'_linux_aarch64.tar.gz'* ]] || exit 1 ;;
        portable) [[ "$(< "$CASE_DIR/downloads.log")" == *'_linux_amd64_no-plugin.tar.gz'* ]] || exit 1 ;;
        check_only) expect test "$(wc -l < "$CASE_DIR/downloads.log")" -eq 1 ;;
    esac
    printf 'PASS %s\n' "$scenario"
done
printf 'All updater integration cases passed. Real systemd was not invoked.\n'