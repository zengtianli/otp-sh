#!/bin/sh
# otp-sh 安装器。非交互，跑完直接生效（权限那一步除外，那是系统强制的人工动作）。
#
#   ./install.sh              装 + 起
#   ./install.sh --uninstall  卸干净
set -eu

SRC=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PREFIX="${OTP_PREFIX:-$HOME/.local/share/otp-sh}"
LABEL=com.otpsh.watch
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_=$(id -u)

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$PREFIX"
  echo "已卸载。状态与日志保留在 ~/.local/state/otp-sh/（要一并删就 rm -rf 它）"
  echo "记得去「系统设置 → 隐私与安全性 → 完全磁盘访问权限」把 otp-shell 那条删掉。"
  exit 0
fi

mkdir -p "$PREFIX" "$HOME/Library/LaunchAgents"
install -m 755 "$SRC/otp.sh" "$PREFIX/otp.sh"

# --- 私有 shell 副本 -------------------------------------------------------
# macOS 的 TCC 把权限记在「实际 exec 的那个 Mach-O」上，脚本本身拿不到身份 ——
# 一个 #!/bin/sh 脚本的权限身份是 /bin/sh。
# 如果直接给系统 /bin/sh 开完全磁盘访问，等于机器上任何一个 shell 脚本都能读你全盘。
# 所以复制一份 sh 出来单独签名，只给这一份授权，爆炸半径就只有本工具。
cp /bin/sh "$PREFIX/otp-shell"
chmod 755 "$PREFIX/otp-shell"
codesign -s - -f "$PREFIX/otp-shell" >/dev/null 2>&1 || {
  echo "codesign 失败——没有它 TCC 认不出这个副本。装了 Xcode command line tools 吗？" >&2
  exit 1
}

# --- 建 launchd 作业 -------------------------------------------------------
# WatchPaths 而不是 StartInterval：只有被监视的文件真的被写才唤醒。
# 空闲时没有任何进程存在，CPU 与内存都是 0。
WATCH=""
add_watch() { [ -e "$1" ] && WATCH="$WATCH		<string>$1</string>
"; }
add_watch "$HOME/Library/Messages/chat.db-wal"
add_watch "$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db-wal"
for mb in "$HOME"/Library/Mail/V*/*/INBOX.mbox; do add_watch "$mb"; done

if [ -z "$WATCH" ]; then
  echo "没有找到任何可监视的路径（信息/钉钉/邮件都不在？）装不下去。" >&2
  exit 1
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$PREFIX/otp-shell</string>
		<string>$PREFIX/otp.sh</string>
	</array>
	<key>WatchPaths</key>
	<array>
$WATCH	</array>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
</dict>
</plist>
EOF

# --- 打基线：不要把历史消息当新验证码 --------------------------------------
"$PREFIX/otp-shell" "$PREFIX/otp.sh" --seed || true

launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PLIST"

echo
echo "已安装：$PREFIX"
echo "作业：  $LABEL  （监视 $(printf '%s' "$WATCH" | grep -c string) 个路径）"
echo
echo "还差一步，只有你能做（系统强制）："
echo "  在刚打开的面板里点 +，选到这个文件加进「完全磁盘访问权限」："
echo "      $PREFIX/otp-shell"
echo "  （Finder 里按 ⌘⇧G 粘贴上面这行路径）"
echo
echo "加完验证： $PREFIX/otp-shell $PREFIX/otp.sh --dry-run"
[ "${OTP_NO_OPEN:-0}" = 1 ] || open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
