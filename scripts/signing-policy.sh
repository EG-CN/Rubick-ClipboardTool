#!/bin/bash
# Shared by both packaging entry points. No implicit ad-hoc fallback.
rubick_require_signing_identity() {
    if [ -z "${RUBICK_SIGN_IDENTITY:-}" ] && [ -f .signing/identity.sha1 ]; then
        RUBICK_SIGN_IDENTITY=$(cat .signing/identity.sha1)
    fi
    if [ -z "${RUBICK_SIGN_IDENTITY:-}" ] || [ "$RUBICK_SIGN_IDENTITY" = "-" ]; then
        echo "更新已停止：请用 RUBICK_SIGN_IDENTITY 指定固定代码签名证书。不会自动退回临时签名。" >&2
        return 1
    fi
}

rubick_sign_app() {
    local app="$1" installed="/Applications/拉比克.app" requirement
    rubick_require_signing_identity || return 1
    codesign --force --sign "$RUBICK_SIGN_IDENTITY" "$app" || return 1
    codesign --verify --strict "$app" || return 1
    rubick_verify_update "$app"
}

rubick_verify_update() {
    local app="$1" installed="/Applications/拉比克.app" requirement
    codesign --verify --strict "$app" || return 1
    if [ -d "$installed" ] && [ "$app" != "$installed" ]; then
        requirement=$(codesign -d -r- "$installed" 2>&1 | sed -n 's/^designated => //p')
        if [ -z "$requirement" ] || ! codesign --verify --strict -R "=$requirement" "$app"; then
            if [ "${RUBICK_ALLOW_SIGNING_MIGRATION:-}" = "1" ] &&
               codesign -dv "$installed" 2>&1 | grep -q 'Signature=adhoc' &&
               [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed/Contents/Info.plist")" ]; then
                echo "执行已授权的一次性迁移：临时签名 → 固定证书；需重新确认系统权限。"
                return 0
            fi
            echo "更新已停止：新包不匹配已安装版本的签名身份；需要单独安排签名迁移与重新授权。" >&2
            return 1
        fi
    fi
}
