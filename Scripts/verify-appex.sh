#!/usr/bin/env bash
# 校验 appex 是一个「真正可加载」的扩展，而不是空壳。
#
# 为什么需要这个检查：有两条坑都会让「注册成功、签名 OK、App 能开，但 Mail 里看不到扩展」：
#   1. Xcode 16+ 的 Debug Dylib（ENABLE_DEBUG_DYLIB）会把 appex 的真实代码挪进
#      xxx.debug.dylib，主可执行文件只剩 stub。App 扩展没有 main() 入口 ——
#      宿主是 dlopen appex 后按 NSExtensionPrincipalClass 去查类，stub 的 main 不会跑。
#   2. appex 没有沙盒 entitlement —— macOS 要求 app 扩展必须沙盒化，否则 pkd 不注册它。
# 这个脚本把这两类情况一并拦下来，避免带着坏产物去装。

set -uo pipefail

APP="${1:-.build/DerivedData/Build/Products/Debug/Mailingo.app}"
APPEX="$APP/Contents/PlugIns/MailingoMailExtension.appex"
BIN="$APPEX/Contents/MacOS/MailingoMailExtension"
PRINCIPAL_CLASS="MailingoMailExtension.MailingoMailExtension"

ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
FAIL=0

# ★ 先把命令输出整个取回来，再判断。
#   绝对不要写成 `nm ... | grep -q ...`：grep -q 命中即退出并关闭管道，
#   上游（nm/otool/codesign）会收到 SIGPIPE 而非零退出；本脚本开了 pipefail，
#   于是整条管道被判为失败 —— 结果是「符号明明存在却报未导出」的**假失败**，
#   而且是时序相关的、时有时无。这个 bug 真实误导过一次排查。
capture() { "$@" 2>/dev/null || true; }

printf '\033[1m── appex 可加载性校验 ──────────────────────────────\033[0m\n'
printf '  %s\n\n' "$APPEX"

[ -d "$APPEX" ] && ok "appex 存在" || { bad "appex 不存在：${APPEX}"; exit 1; }
[ -x "$BIN" ]   && ok "主可执行文件存在" || { bad "主可执行文件不存在"; exit 1; }

# 1) 不能有 debug dylib
DEBUG_DYLIBS=$(find "$APPEX" -name "*.debug.dylib" 2>/dev/null)
if [ -n "$DEBUG_DYLIBS" ]; then
  bad "发现 *.debug.dylib —— 这是 stub 构建，Mail 无法加载扩展"
  printf '      \033[2m修复：确保 project.yml 里 ENABLE_DEBUG_DYLIB: NO，然后重新构建\033[0m\n'
  printf '%s\n' "$DEBUG_DYLIBS" | sed 's/^/      /'
else
  ok "没有 debug dylib（代码在主可执行文件里）"
fi

# 2) 必须真的链接 MailKit
LINKED=$(capture otool -L "$BIN")
if grep -q "MailKit.framework" <<<"$LINKED"; then
  ok "链接了 MailKit.framework"
else
  bad "没有链接 MailKit.framework —— 说明 MailKit 代码没被编译进 appex"
fi

# 3) appex 必须沙盒化
ENTITLEMENTS=$(capture codesign -d --entitlements - --xml "$APPEX")
if grep -q "app-sandbox" <<<"$ENTITLEMENTS"; then
  ok "appex 已沙盒化（com.apple.security.app-sandbox）"
else
  bad "appex 没有沙盒 entitlement —— pkd 不会注册，Mail 扩展面板会一直是空的"
  printf '      \033[2m修复：project.yml 里给 appex target 设 ENABLE_APP_SANDBOX: YES\033[0m\n'
fi

# 4) 必须导出 principal class 的 ObjC 符号
#
#    实测这个检查出现过「同一个二进制先报未导出、十几秒后再查就通过」的瞬时抖动。
#    已排除的原因：SIGPIPE —— nm -g 的输出只有 ~19KB，远小于 64KB 管道缓冲区，
#    所以 `nm | grep -q` 里 nm 不会被 SIGPIPE 打断（实测管道退出码为 0）。
#    真正原因未定位，因此这里：① 有限次重试；② 失败时把原始证据打出来，
#    而不是只丢一句结论 —— 下次复现就能直接定位。
check_principal_symbol() {
  local attempt=1 max=3 syms rc errfile
  errfile=$(mktemp)

  while [ "$attempt" -le "$max" ]; do
    syms=$(nm -g "$BIN" 2>"$errfile")
    rc=$?
    if grep -q "OBJC_CLASS.*MailingoMailExtension" <<<"$syms"; then
      ok "导出了 principal class 的 ObjC 符号"
      rm -f "$errfile"
      return 0
    fi
    if [ "$attempt" -lt "$max" ]; then
      printf '      \033[2m第 %s 次未命中，重试…\033[0m\n' "$attempt"
      sleep 0.5
    fi
    attempt=$((attempt + 1))
  done

  bad "未导出 principal class 的 ObjC 符号（${PRINCIPAL_CLASS}）"
  printf '      \033[2mnm 退出码=%s  输出=%s 字节 / %s 行\033[0m\n' \
    "$rc" "$(printf '%s' "$syms" | wc -c | tr -d ' ')" "$(printf '%s' "$syms" | wc -l | tr -d ' ')"
  printf '      \033[2m二进制 %s 字节  mtime=%s  sha=%s\033[0m\n' \
    "$(stat -f '%z' "$BIN")" "$(stat -f '%Sm' "$BIN")" "$(shasum "$BIN" | cut -c1-12)"
  if [ -s "$errfile" ]; then
    printf '      \033[2mnm stderr：\033[0m\n'
    head -5 "$errfile" | sed 's/^/        /'
  fi
  rm -f "$errfile"
  return 1
}
check_principal_symbol

# 5) Info.plist 里的 principal class 要和模块名对得上
PLIST_PRINCIPAL=$(capture /usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPrincipalClass" "$APPEX/Contents/Info.plist")
if [ "${PLIST_PRINCIPAL}" = "${PRINCIPAL_CLASS}" ]; then
  ok "Info.plist principal class = ${PLIST_PRINCIPAL}"
else
  bad "principal class 不匹配：plist 里是「${PLIST_PRINCIPAL}」，期望「${PRINCIPAL_CLASS}」"
fi

PLIST_POINT=$(capture /usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" "$APPEX/Contents/Info.plist")
if [ "${PLIST_POINT}" = "com.apple.email.extension" ]; then
  ok "extension point = com.apple.email.extension"
else
  bad "extension point 不对：「${PLIST_POINT}」"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '  \033[32m全部通过\033[0m —— 可以安装并到 Mail 里启用。\n\n'
else
  printf '  \033[31m校验失败\033[0m —— 先修好再安装，否则 Mail 里一定看不到扩展。\n\n'
fi
exit "$FAIL"
