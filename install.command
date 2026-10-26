#!/bin/bash
# macOS built-in tools only. Run as the Mac's signed-in user, without sudo.
set -euo pipefail
umask 077

crd_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
crd_modules=(lang1-korean.lua key-input.lua key-registration.lua)
crd_skip_registration=0
crd_config_dir="$HOME/.hammerspoon"
crd_app_dir=""
crd_config_only=0
crd_no_launch=0
crd_dry_run=0
crd_tmp=""
crd_staged_app=""
crd_staged_file=""
crd_backup=""
crd_changed=0

crd_log() { printf '%s\n' "$*"; }
crd_fail() { printf '설치를 중단했습니다: %s\n' "$*" >&2; exit 1; }
crd_cleanup() {
    if [ -n "$crd_staged_file" ]; then /bin/rm -f -- "$crd_staged_file"; fi
    if [ -n "$crd_staged_app" ]; then /bin/rm -rf -- "$crd_staged_app"; fi
    if [ -n "$crd_tmp" ]; then /bin/rm -rf -- "$crd_tmp"; fi
}
trap crd_cleanup EXIT

crd_usage() {
    cat <<'HELP'
Chrome 원격 한영키 등록 및 설치

사용: install.command [옵션]
  --dry-run          변경하지 않고 설치 계획만 표시
  --config-only      Hammerspoon 앱 다운로드와 설치 생략
  --no-launch        앱 재실행과 시스템 설정 화면 열기 생략
  --skip-registration  새 키 등록 요청을 생략하고 기존 매핑 유지
  --config-dir 경로  설정 폴더 지정 (기본: ~/.hammerspoon)
  --app-dir 경로     앱 설치 폴더 지정 (기본: /Applications, 쓰기 불가 시 ~/Applications)
  --help             이 안내 표시

Xcode, Python, Homebrew는 필요하지 않습니다. sudo로 실행하지 마세요.
다른 설정 폴더를 지정했다면 Hammerspoon도 그 설정 폴더를 사용해야 합니다.
HELP
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) crd_dry_run=1; shift ;;
        --config-only) crd_config_only=1; shift ;;
        --no-launch) crd_no_launch=1; shift ;;
        --skip-registration) crd_skip_registration=1; shift ;;
        --config-dir|--app-dir)
            [ "$#" -ge 2 ] || crd_fail "$1 뒤에 절대 경로를 지정해 주세요."
            case "$2" in /*) ;; *) crd_fail "절대 경로를 지정해 주세요: $2" ;; esac
            if [ "$1" = --config-dir ]; then crd_config_dir="$2"; else crd_app_dir="$2"; fi
            shift 2 ;;
        --help|-h) crd_usage; exit 0 ;;
        *) crd_fail "알 수 없는 옵션: $1 (--help 참고)" ;;
    esac
done

[ "$(/usr/bin/uname -s)" = Darwin ] || crd_fail 'macOS에서 실행해 주세요.'
[ "$EUID" -ne 0 ] || crd_fail '로그인한 사용자 계정으로 실행해 주세요. sudo는 필요하지 않습니다.'
for crd_name in "${crd_modules[@]}"; do
    [ -f "$crd_script_dir/$crd_name" ] || crd_fail "같은 폴더의 $crd_name 파일이 필요합니다. 압축을 모두 풀어 주세요."
done
case "$crd_config_dir" in /) crd_fail '설정 폴더로 / 를 사용할 수 없습니다.' ;; esac

crd_init="$crd_config_dir/init.lua"
crd_request="$crd_config_dir/.crd-register-key"
if [ -L "$crd_request" ] || { [ -e "$crd_request" ] && [ ! -f "$crd_request" ]; }; then
    crd_fail "키 등록 요청 경로가 일반 파일이 아닙니다: $crd_request"
fi
crd_paths=("$crd_init")
for crd_name in "${crd_modules[@]}"; do crd_paths+=("$crd_config_dir/$crd_name"); done
for crd_path in "${crd_paths[@]}"; do
    if { [ -e "$crd_path" ] || [ -L "$crd_path" ]; } && [ ! -f "$crd_path" ]; then
        crd_fail "일반 파일이 아닌 경로를 확인해 주세요: $crd_path"
    fi
    if [ -f "$crd_path" ] && [ ! -w "$crd_path" ]; then
        crd_fail "파일에 쓰기 권한이 없습니다: $crd_path"
    fi
done

# Recognize our active block at the start, not a filename inside a comment/string.
# An earlier manual dofile is harmless: the module itself refuses a second load.
crd_has_loader=0
if [ -f "$crd_init" ] && LC_ALL=C /usr/bin/awk '
    NR==1 {
        bom=sprintf("%c%c%c",239,187,191)
        if (substr($0,1,3)==bom) $0=substr($0,4)
        if ($0 ~ /^#!/) next
    }
    !started { started=1; if ($0!="-- BEGIN Chrome Remote Lang1 Korean") exit; step=1; next }
    step==1 { if ($0!="dofile(hs.configdir .. \"/lang1-korean.lua\")") exit; step=2; next }
    step==2 { if ($0=="-- END Chrome Remote Lang1 Korean") found=1; exit }
    END { exit !found }
' "$crd_init"; then crd_has_loader=1; fi

# The earlier inline configuration already handles key 104. Do not add a second handler.
if [ -f "$crd_init" ] && /usr/bin/grep -Eq '^[[:space:]]*(remoteKorean|crdLang1Korean)[[:space:]]*=' "$crd_init"; then
    crd_fail 'init.lua에 이전 한/영 설정이 직접 들어 있습니다. 중복 전환 방지를 위해 수정하지 않았습니다. 이미 동작한다면 설치할 필요가 없습니다.'
fi

for crd_name in "${crd_modules[@]}"; do
    if ! /usr/bin/cmp -s "$crd_script_dir/$crd_name" "$crd_config_dir/$crd_name"; then crd_changed=1; fi
done
if [ "$crd_has_loader" = 0 ]; then crd_changed=1; fi

crd_app=""
if [ -n "$crd_app_dir" ]; then
    crd_app="$crd_app_dir/Hammerspoon.app"
elif [ -d /Applications/Hammerspoon.app ]; then
    crd_app=/Applications/Hammerspoon.app
    crd_app_dir=/Applications
elif [ -d "$HOME/Applications/Hammerspoon.app" ]; then
    crd_app="$HOME/Applications/Hammerspoon.app"
    crd_app_dir="$HOME/Applications"
else
    if [ -w /Applications ]; then crd_app_dir=/Applications; else crd_app_dir="$HOME/Applications"; fi
    crd_app="$crd_app_dir/Hammerspoon.app"
fi

crd_log 'Chrome 원격 한영키 등록 및 설치'
crd_log "설정 폴더: $crd_config_dir"
crd_log "Hammerspoon: $crd_app"
if [ "$crd_dry_run" = 1 ]; then
    crd_log "계획: 앱 설치 생략=$crd_config_only, 설정 변경 필요=$crd_changed, 앱 실행 생략=$crd_no_launch, 키 등록 생략=$crd_skip_registration"
    crd_log '파일, 앱, 권한을 변경하지 않았습니다.'
    exit 0
fi

crd_check_app() {
    local crd_bundle_id
    crd_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null)" || return 1
    [ "$crd_bundle_id" = org.hammerspoon.Hammerspoon ] && [ -x "$1/Contents/MacOS/Hammerspoon" ]
}

if [ "$crd_config_only" = 0 ]; then
    if [ -e "$crd_app" ] || [ -L "$crd_app" ]; then
        crd_check_app "$crd_app" || crd_fail "기존 경로가 Hammerspoon 앱이 아닙니다: $crd_app"
        crd_log '기존 Hammerspoon을 재사용합니다.'
    else
        crd_log 'Hammerspoon 공식 GitHub 배포본을 다운로드합니다.'
        crd_tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/crd-lang1.XXXXXX")"
        /usr/bin/curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 60 \
            --proto '=https' --proto-redir '=https' \
            -H 'Accept: application/vnd.github+json' \
            'https://api.github.com/repos/Hammerspoon/hammerspoon/releases/latest' \
            -o "$crd_tmp/release.json" || crd_fail '공식 배포 정보를 받지 못했습니다. 인터넷 연결을 확인해 주세요.'
        crd_download_url=""
        crd_index=0
        while [ "$crd_index" -lt 64 ]; do
            crd_asset_name="$(/usr/bin/plutil -extract "assets.$crd_index.name" raw -o - "$crd_tmp/release.json" 2>/dev/null)" || break
            case "$crd_asset_name" in
                Hammerspoon-*.zip)
                    crd_download_url="$(/usr/bin/plutil -extract "assets.$crd_index.browser_download_url" raw -o - "$crd_tmp/release.json")"
                    break ;;
            esac
            crd_index=$((crd_index + 1))
        done
        case "$crd_download_url" in
            https://github.com/Hammerspoon/hammerspoon/releases/download/*/Hammerspoon-*.zip) ;;
            *) crd_fail '공식 Hammerspoon ZIP 주소를 찾지 못했습니다. https://www.hammerspoon.org/ 에서 설치 후 다시 실행해 주세요.' ;;
        esac
        /usr/bin/curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 240 \
            --proto '=https' --proto-redir '=https' "$crd_download_url" \
            -o "$crd_tmp/Hammerspoon.zip" || crd_fail 'Hammerspoon 다운로드에 실패했습니다.'
        /usr/bin/ditto -x -k "$crd_tmp/Hammerspoon.zip" "$crd_tmp/expanded"
        crd_check_app "$crd_tmp/expanded/Hammerspoon.app" || crd_fail '다운로드한 앱 형식을 확인하지 못했습니다.'
        /usr/bin/codesign --verify --deep --strict "$crd_tmp/expanded/Hammerspoon.app" \
            || crd_fail '앱 서명 검증에 실패했습니다. 앱은 설치하지 않았습니다.'
        /usr/sbin/spctl --assess --type execute "$crd_tmp/expanded/Hammerspoon.app" \
            || crd_fail 'macOS의 앱 실행 검증을 통과하지 못했습니다. 앱은 설치하지 않았습니다.'
        /bin/mkdir -p "$crd_app_dir"
        [ ! -e "$crd_app" ] || crd_fail '설치 중 같은 이름의 앱이 생겼습니다. 다시 실행해 주세요.'
        crd_stage_candidate="$crd_app_dir/.Hammerspoon-install-$$.app"
        /bin/mkdir "$crd_stage_candidate" || crd_fail '임시 앱 폴더를 만들지 못했습니다.'
        crd_staged_app="$crd_stage_candidate"
        /usr/bin/ditto "$crd_tmp/expanded/Hammerspoon.app" "$crd_staged_app"
        /bin/mv "$crd_staged_app" "$crd_app"
        crd_staged_app=""
        crd_log 'Hammerspoon 앱 설치 완료.'
    fi
fi

# Resolve file symlinks, so replacing a file preserves the user's dotfile link.
crd_resolve_target() {
    local crd_target="$1" crd_link crd_count=0 crd_parent
    while [ -L "$crd_target" ]; do
        crd_count=$((crd_count + 1))
        [ "$crd_count" -lt 40 ] || return 1
        crd_link="$(/usr/bin/readlink "$crd_target")" || return 1
        case "$crd_link" in
            /*) crd_target="$crd_link" ;;
            *) crd_target="$(/usr/bin/dirname "$crd_target")/$crd_link" ;;
        esac
    done
    crd_parent="$(cd -- "$(/usr/bin/dirname "$crd_target")" && pwd -P)" || return 1
    printf '%s/%s\n' "$crd_parent" "$(/usr/bin/basename "$crd_target")"
}

if [ "$crd_changed" = 1 ]; then
    /bin/mkdir -p "$crd_config_dir"
    crd_backup="$crd_config_dir/backups/chrome-remote-lang1/$(/bin/date +%Y%m%d-%H%M%S)-$$"
    /bin/mkdir -p "$crd_backup"
    for crd_path in "${crd_paths[@]}"; do
        if [ -f "$crd_path" ]; then /bin/cp -p "$crd_path" "$crd_backup/$(/usr/bin/basename "$crd_path")"; fi
    done
    printf '설정 폴더: %s\n기존 init.lua의 설정 본문은 유지합니다.\n' "$crd_config_dir" > "$crd_backup/복원안내.txt"
    crd_log "기존 설정 백업: $crd_backup"

    for crd_name in "${crd_modules[@]}"; do
        if /usr/bin/cmp -s "$crd_script_dir/$crd_name" "$crd_config_dir/$crd_name"; then continue; fi
        crd_target="$(crd_resolve_target "$crd_config_dir/$crd_name")" || crd_fail '모듈 파일의 링크를 확인해 주세요.'
        crd_staged_file="$(/usr/bin/mktemp "$(/usr/bin/dirname "$crd_target")/.crd-lang1.XXXXXX")"
        if [ -f "$crd_target" ]; then /bin/cp -p "$crd_target" "$crd_staged_file"; fi
        /bin/cat "$crd_script_dir/$crd_name" > "$crd_staged_file"
        /bin/mv -f "$crd_staged_file" "$crd_target"
        crd_staged_file=""
    done
    if [ "$crd_has_loader" = 0 ]; then
        crd_target="$(crd_resolve_target "$crd_init")" || crd_fail 'init.lua의 링크를 확인해 주세요.'
        crd_staged_file="$(/usr/bin/mktemp "$(/usr/bin/dirname "$crd_target")/.crd-lang1.XXXXXX")"
        if [ -f "$crd_target" ]; then /bin/cp -p "$crd_target" "$crd_staged_file"; fi
        # Prepend before an existing top-level return. Preserve a BOM/shebang.
        crd_init_input=/dev/null
        if [ -f "$crd_init" ]; then crd_init_input="$crd_init"; fi
        LC_ALL=C /usr/bin/awk '
            function loader() {
                print "-- BEGIN Chrome Remote Lang1 Korean"
                print "dofile(hs.configdir .. \"/lang1-korean.lua\")"
                print "-- END Chrome Remote Lang1 Korean"
                print ""
            }
            NR == 1 {
                bom=sprintf("%c%c%c",239,187,191)
                if (substr($0,1,3)==bom) { printf "%s",bom; $0=substr($0,4) }
                if ($0 ~ /^#!/) { print; loader(); next }
                loader()
            }
            { print }
            END { if (NR==0) loader() }
        ' "$crd_init_input" > "$crd_staged_file" || crd_fail 'init.lua를 준비하지 못했습니다. 표시된 백업 폴더를 확인해 주세요.'
        /bin/mv -f "$crd_staged_file" "$crd_target"
        crd_staged_file=""
    fi
    crd_log '설정 파일 배치와 init.lua 연결 완료.'
else
    crd_log '같은 설정이 이미 설치되어 있습니다. 중복으로 추가하지 않았습니다.'
fi

if [ "$crd_skip_registration" = 0 ]; then
    /bin/mkdir -p "$crd_config_dir"
    crd_staged_file="$(/usr/bin/mktemp "$crd_config_dir/.crd-request.XXXXXX")"
    printf 'register\n' > "$crd_staged_file"
    /bin/mv -f "$crd_staged_file" "$crd_request"
    crd_staged_file=""
    crd_log 'Hammerspoon에서 두 번 입력하여 한/영키를 등록하도록 요청했습니다.'
elif [ -f "$crd_request" ]; then
    /bin/rm -f -- "$crd_request"
fi

if [ "$crd_no_launch" = 0 ] && crd_check_app "$crd_app"; then
    if { [ "$crd_changed" = 1 ] || [ "$crd_skip_registration" = 0 ]; } && /usr/bin/pgrep -u "$UID" -x Hammerspoon >/dev/null 2>&1; then
        crd_log '새 설정을 불러오기 위해 Hammerspoon을 다시 실행합니다.'
        /usr/bin/pkill -TERM -u "$UID" -x Hammerspoon || true
        crd_wait=0
        while /usr/bin/pgrep -u "$UID" -x Hammerspoon >/dev/null 2>&1; do
            crd_wait=$((crd_wait + 1))
            [ "$crd_wait" -lt 50 ] || crd_fail 'Hammerspoon을 직접 종료한 뒤 다시 실행해 주세요. 설정 파일은 저장되었습니다.'
            /bin/sleep 0.1
        done
    fi
    # Launch Services can briefly retain the terminated process (error -600).
    crd_launch_try=0
    until /usr/bin/open -a "$crd_app" >/dev/null 2>&1; do
        crd_launch_try=$((crd_launch_try + 1))
        [ "$crd_launch_try" -lt 8 ] || crd_fail '설정은 저장했습니다. Hammerspoon을 직접 실행해 주세요.'
        /bin/sleep 0.5
    done
    /usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' || true
fi

crd_log ''
crd_log '파일 설정을 마쳤습니다. 아래 단계는 각 사용자가 직접 완료해 주세요.'
crd_log '1. Mac의 손쉬운 사용에서 Hammerspoon 허용 → 처음 허용했다면 앱 다시 실행'
crd_log '2. Mac의 키보드 입력 소스에 ABC와 한국어 두벌식 추가'
crd_log '3. 원격 화면의 등록 창에서 입력 시작 → 한/영키 1회 → 확인 → 같은 키 1회'
crd_log '   입력이 Mac에 도착하지 않으면 Chrome 원격의 대상 키를 Lang1으로 매핑한 뒤 다시 등록'
crd_log '4. 등록 후 원격 한/영키와 메뉴 막대 한/영 버튼으로 전환 확인'
crd_log '다시 등록: install.command 재실행 또는 메뉴 한/영을 Option+클릭'
crd_log '선택: Hammerspoon Preferences의 Launch Hammerspoon at login 켜기'
if [ "$crd_no_launch" = 1 ]; then crd_log '앱 실행을 생략했습니다. 준비가 되면 Hammerspoon을 실행하거나 Reload Config를 선택하세요.'; fi
