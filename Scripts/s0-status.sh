#!/usr/bin/env bash
# S0 探针判定摘要。
# 用法：make status   （或直接 bash Scripts/s0-status.sh）

set -uo pipefail

# appex 必须沙盒化，日志写在它自己的沙盒容器里；容器 App 非沙盒，能直接读。
CONTAINER="$HOME/Library/Containers/com.zhuyuhao.Mailingo.MailExtension/Data/Library/Logs/Mailingo"
LEGACY="$HOME/Library/Logs/Mailingo"

# 容器里的优先；仅当容器没有、而旧位置有时才退回旧位置；两者都没有时默认显示容器（新日志会写在那）。
if [ -f "$CONTAINER/probe.log" ]; then
  LOGDIR="$CONTAINER"
elif [ -f "$LEGACY/probe.log" ]; then
  LOGDIR="$LEGACY"
else
  LOGDIR="$CONTAINER"
fi
LOG="$LOGDIR/probe.log"
EML="$LOGDIR/last-message.eml"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
no()   { printf '  \033[31m✗\033[0m %s\n' "$1"; }
hint() { printf '      \033[2m%s\033[0m\n' "$1"; }

has() { [ -f "$LOG" ] && grep -qF "$1" "$LOG"; }

bold "── S0 探针状态 ─────────────────────────────────────"
printf '  日志：%s\n' "$LOG"
if [ -f "$LOG" ]; then
  printf '  大小：%s 行 / 最后更新 %s\n' "$(wc -l < "$LOG" | tr -d ' ')" "$(stat -f '%Sm' "$LOG")"
else
  printf '  \033[33m日志还不存在\033[0m —— 说明扩展从未被 Mail 加载过。\n'
fi
echo

bold "判定清单"

if [ -f "$LOG" ] && has "MailingoMailExtension 已实例化"; then
  ok "1. Mail 已加载扩展"
  failed1=0
else
  no "1. Mail 还没加载扩展"
  hint "Mail → 设置 → 扩展 → 勾选 Mailingo，然后完全退出并重启 Mail"
  failed1=1
fi

if has "decodedMessage(forMessageData:) 被调用"; then
  n=$(grep -cF "decodedMessage(forMessageData:) 被调用" "$LOG")
  ok "2. 普通邮件也调用了 decodedMessage(forMessageData:)  ★核心结论成立★ （已 $n 次）"
  failed2=0
else
  no "2. 还没观察到 decodedMessage(forMessageData:) 被调用"
  hint "在 Mail 里点开几封**普通未加密未签名**的邮件（不要选 S/MIME 加密的）"
  failed2=1
fi

if has "extensionViewController" || has "primaryActionClicked"; then
  ok "3. 点击后 Mail 呈现了我们的 MEExtensionViewController  ★入口可用★"
  failed3=0
else
  no "3. 还没观察到 Mail 呈现我们的视图控制器"
  hint "回到 Mail，点邮件顶部的「Mailingo 探针：翻译这封邮件」横幅上的「翻译」，或邮件头部的扩展图标"
  failed3=1
fi

if [ -f "$EML" ] && [ "$(stat -f '%z' "$EML")" -gt 64 ]; then
  ok "4. 拿到完整原始 MIME：$(stat -f '%z' "$EML") bytes → $EML"
  failed4=0
else
  no "4. 还没拿到原始 MIME"
  failed4=1
fi

echo
bold "── 结论 ────────────────────────────────────────────"
if [ "${failed2:-1}" -eq 0 ] && [ "${failed3:-1}" -eq 0 ] && [ "${failed4:-1}" -eq 0 ]; then
  printf '  \033[32mS0 通过\033[0m：Mail 扩展可以作为「入口 + 数据源」。\n'
  printf '  → 采用 docs/IMPLEMENTATION_PLAN.md §2.5 的\033[1m架构 C\033[0m（扩展做入口，容器 App 做吸附侧栏）。\n'
  printf '  → 附带收益：翻译链路\033[1m完全不需要 Automation / Apple Events 权限\033[0m。\n'
elif [ "${failed1:-1}" -eq 1 ]; then
  printf '  \033[33m尚未开始\033[0m：先让 Mail 加载扩展。\n'
else
  printf '  \033[33m未完成\033[0m：按上面每一条的提示操作后，重新运行 make status。\n'
fi
echo
printf '  \033[2m提示：切换开关可对比两种行为 —— 容器 App 里的「开关」按钮，\033[0m\n'
printf '  \033[2m      或 touch/rm %s/return-nil，改完无需重装、无需重启 Mail。\033[0m\n' "$LOGDIR"
echo
