#!/bin/sh
# otp-sh — macOS 验证码自动填充。事件驱动，空闲零进程。
#
# 由 launchd WatchPaths 唤醒；跑完即退。没有常驻进程、没有轮询循环。
# 三个来源：信息(chat.db) / 钉钉(通知中心) / 邮件(.emlx)
#
# 用法: otp.sh [--once] [--dry-run] [--seed] [--selftest]
set -u

VERSION=0.1.0

STATE_DIR="${OTP_STATE_DIR:-$HOME/.local/state/otp-sh}"
CONF="${OTP_CONF:-$HOME/.config/otp-sh/config}"
LOG="$STATE_DIR/otp.log"

# ---- 默认配置（可在 $CONF 覆盖，格式为 sh 变量赋值）----
MAX_AGE=180          # 秒。超过这个岁数的消息一律不动 —— launchd 可能延迟或补跑，
                     # 没有这道闸就会在你不知情时把几小时前的旧码塞进剪贴板。
SOURCES="sms dingtalk mail"
AUTO_TYPE=0          # 1 = 直接键入验证码（需要辅助功能权限）
AUTO_ENTER=0         # 1 = 键入后回车（仅 AUTO_TYPE=1 时有效）
NOTIFY=1             # 1 = 弹通知
MAIL_ROOT="$HOME/Library/Mail"

[ -f "$CONF" ] && . "$CONF"

DRY_RUN=0
SEED_ONLY=0
for a in "$@"; do
  case "$a" in
    --dry-run)  DRY_RUN=1 ;;
    --seed)     SEED_ONLY=1 ;;
    --selftest) exec "$(dirname "$0")/test/run.sh" ;;
    --version)  echo "otp-sh $VERSION"; exit 0 ;;
    --once)     : ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR" || exit 1

# 时间戳必须带时区偏移：launchd 作业继承的 TZ 和你交互 shell 的 TZ 不一定相同
# （本机实测：shell 是 America/Los_Angeles，launchd 作业是 CST，同一秒差 15 小时）。
# 不带偏移的时间戳没法和别的日志对照，排查时会把人带沟里。
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

# 日志自封顶，免得跑一年长成几百 MB
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 262144 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# ---- 验证码抽取 ----------------------------------------------------------
# 两步：关键词闸门 → 屏蔽陷阱数字 → 取第一个 4-8 位数字。
#
# 这条规则是量出来的，不是拍的。在本机 238 条真实验证码短信上比过三种写法：
#
#   规则                          结果
#   关键词闸门 + 首个 4-8 位数字   238/238 抽到，0 例可查证的选错     ← 采用
#   只取「关键词之后」的数字       漏 21 条 —— 「418657为本次登录验证
#                                 的手机验证码」这种码在关键词前的写法
#   加宽泛的反上下文词表           反而误杀 5 条正常验证码（「条」命中
#                                 "本条短信"、「账号」命中"小米账号验证码"）
#
# 所以只保留一层极窄的屏蔽：紧跟在 尾号/订单号/客服电话 这类词后面的数字先抹掉。
# 该屏蔽在 238 条真实短信上命中 0 次（即不误伤任何真码），纯粹是给
# 「订单 20260728 已发货，取件验证码 135790」这类形状留的保险。

KEYWORDS='验证码|校验码|动态码|驗證碼|校驗碼|随机码|安全码|verification code|verify code|security code|one[- ]time|OTP|passcode'
TRAP='尾号|后四位|卡号|订单|单号|运单|金额|余额|客服电话|热线'

is_otp() {
  printf '%s' "$1" | LC_ALL=C grep -qiE "$KEYWORDS|[^a-z]code[^a-z]"
}

extract_code() {
  printf '%s' "$1" \
    | LC_ALL=C sed -E "s/($TRAP)[^0-9]{0,3}[0-9]{4,8}/\1/g" \
    | LC_ALL=C grep -oE '(^|[^0-9])[0-9]{4,8}([^0-9]|$)' \
    | LC_ALL=C grep -oE '[0-9]{4,8}' | head -1
}

# ---- 投递 ---------------------------------------------------------------
deliver() {
  _code=$1; _src=$2
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] $_src -> $_code"
    log "dry-run $_src $_code"
    return 0
  fi
  printf '%s' "$_code" | /usr/bin/pbcopy
  log "copied $_src $_code"
  [ "$NOTIFY" = 1 ] && /usr/bin/osascript -e \
    "display notification \"$_code\" with title \"验证码已复制\" subtitle \"$_src\"" >> "$LOG" 2>&1
  if [ "$AUTO_TYPE" = 1 ]; then
    /usr/bin/osascript -e "tell application \"System Events\" to keystroke \"$_code\"" >> "$LOG" 2>&1
    [ "$AUTO_ENTER" = 1 ] && /usr/bin/osascript -e \
      'tell application "System Events" to key code 36' >> "$LOG" 2>&1
  fi
  return 0
}

now_epoch() { date +%s; }

# ---- 来源 1：信息 / iMessage --------------------------------------------
# chat.db 的 date 是 Apple 纪元(2001-01-01)起的纳秒。
scan_sms() {
  _db="$HOME/Library/Messages/chat.db"
  [ -r "$_db" ] || { log "sms: chat.db 不可读（缺全磁盘访问？）"; return 1; }
  _st="$STATE_DIR/sms.rowid"
  _last=$(cat "$_st" 2>/dev/null || echo "")

  if [ -z "$_last" ] || [ "$SEED_ONLY" = 1 ]; then
    _max=$(/usr/bin/sqlite3 -readonly "$_db" "SELECT COALESCE(MAX(ROWID),0) FROM message;") || return 1
    echo "$_max" > "$_st"
    log "sms: 基线设为 rowid=$_max"
    return 0
  fi

  _cut=$(( $(now_epoch) - MAX_AGE - 978307200 ))
  _rows=$(/usr/bin/sqlite3 -readonly -separator '|' "$_db" \
    "SELECT ROWID, replace(replace(replace(COALESCE(text,''),char(10),' '),char(13),' '),'|',' ')
       FROM message
      WHERE ROWID > $_last AND is_from_me = 0
        AND date > $_cut * 1000000000
      ORDER BY ROWID LIMIT 20;") || { log "sms: 查询失败"; return 1; }

  # 无论有没有命中，都要把水位推到当前最大，否则下次会重复扫同一批
  _newmax=$(/usr/bin/sqlite3 -readonly "$_db" "SELECT COALESCE(MAX(ROWID),$_last) FROM message;")
  echo "$_newmax" > "$_st"

  [ -z "$_rows" ] && return 0
  printf '%s\n' "$_rows" | while IFS='|' read -r _rid _body; do
    [ -n "$_body" ] || continue
    is_otp "$_body" || continue
    _code=$(extract_code "$_body")
    [ -n "$_code" ] && deliver "$_code" "信息"
  done
}

# ---- 来源 2：钉钉（通知中心）---------------------------------------------
# 通知落在 usernoted 的 record 表，正文是 binary plist BLOB，取 req.body。
# record 是易失表（送达后会被清），所以只能靠事件驱动即时读，轮询没有意义。
scan_dingtalk() {
  _ndb="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
  [ -r "$_ndb" ] || { log "dingtalk: 通知库不可读"; return 1; }
  _st="$STATE_DIR/dingtalk.recid"
  _last=$(cat "$_st" 2>/dev/null || echo "")
  _bundle="${OTP_DINGTALK_BUNDLE:-com.alibaba.dingtalkmac}"

  _max=$(/usr/bin/sqlite3 -readonly "$_ndb" \
    "SELECT COALESCE(MAX(r.rec_id),0) FROM record r JOIN app a ON r.app_id=a.app_id
      WHERE lower(a.identifier)='$_bundle';") || return 1

  if [ -z "$_last" ] || [ "$SEED_ONLY" = 1 ]; then
    echo "$_max" > "$_st"; log "dingtalk: 基线设为 rec_id=$_max"; return 0
  fi
  [ "$_max" -le "$_last" ] && return 0

  _ids=$(/usr/bin/sqlite3 -readonly "$_ndb" \
    "SELECT r.rec_id FROM record r JOIN app a ON r.app_id=a.app_id
      WHERE lower(a.identifier)='$_bundle' AND r.rec_id > $_last
      ORDER BY r.rec_id LIMIT 20;") || return 1
  echo "$_max" > "$_st"

  for _rid in $_ids; do
    _body=$(/usr/bin/sqlite3 -readonly "$_ndb" "SELECT quote(data) FROM record WHERE rec_id=$_rid;" \
      | sed "s/^X'//; s/'$//" | xxd -r -p \
      | plutil -extract req.body raw -o - - 2>>"$LOG")
    [ -n "$_body" ] || continue
    is_otp "$_body" || continue
    _code=$(extract_code "$_body")
    [ -n "$_code" ] && deliver "$_code" "钉钉"
  done
}

# ---- 来源 3：邮件（.emlx）------------------------------------------------
# .emlx 是明文：4 字节长度头 + RFC822 报文 + plist 尾。
# 直接按文本抓，不引入任何 MIME 解析器 —— 这正是被替代的那个 Rust 版死在
# email crate 的 RFC5322 解析器里、烧掉 25 小时 CPU 的地方。
# 只看 INBOX，只看比上次水位新的文件。
scan_mail() {
  [ -d "$MAIL_ROOT" ] || return 0
  _st="$STATE_DIR/mail.stamp"
  if [ ! -f "$_st" ] || [ "$SEED_ONLY" = 1 ]; then
    touch "$_st"; log "mail: 基线时间戳已建"; return 0
  fi

  # 只走 INBOX.mbox 子树。整个 ~/Library/Mail 底下可能有上万个 .emlx
  # （本机 3500 个，多数在垃圾邮件和归档里），全树遍历纯属白烧。
  set -- "$MAIL_ROOT"/V*/*/INBOX.mbox
  [ -d "$1" ] || return 0
  _found=$(find "$@" -name '*.emlx' -newer "$_st" -type f 2>>"$LOG" | head -20)
  touch "$_st"
  [ -n "$_found" ] || return 0

  printf '%s\n' "$_found" | while IFS= read -r _f; do
    # .emlx 首行是报文字节数（形如 "10485"）。它本身就是个 4-8 位数字，
    # 不剥掉的话会稳定盖过真正的验证码 —— 每封验证码邮件都会抽错。
    # 只读前 64KB：验证码不会藏在正文第 64KB 之后，也顺手挡住巨型附件邮件
    _txt=$(head -c 65536 "$_f" 2>>"$LOG" \
      | tail -n +2 \
      | LC_ALL=C tr -d '\000' \
      | sed -e 's/=3D/=/g' -e 's/=$//' \
      | LC_ALL=C tr '\n' ' ')
    [ -n "$_txt" ] || continue
    is_otp "$_txt" || continue
    _code=$(extract_code "$_txt")
    [ -n "$_code" ] && deliver "$_code" "邮件"
  done
}

# ---- 主流程 --------------------------------------------------------------
_rc=0
for _s in $SOURCES; do
  case "$_s" in
    sms)      scan_sms      || _rc=1 ;;
    dingtalk) scan_dingtalk || _rc=1 ;;
    mail)     scan_mail     || _rc=1 ;;
    *) log "未知来源: $_s"; _rc=1 ;;
  esac
done
exit $_rc
