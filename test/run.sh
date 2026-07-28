#!/bin/sh
# otp-sh 自测。不碰真实数据库，只测抽取规则。
# 用法: test/run.sh   （退出码非 0 = 有用例挂了）
set -u

DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

# 只加载函数定义，不执行主流程
OTP_STATE_DIR=$(mktemp -d)
export OTP_STATE_DIR
eval "$(sed -n '/^KEYWORDS=/,/^}/p;/^extract_code()/,/^}/p' "$DIR/otp.sh")"

pass=0; fail=0
check() { # check <期望> <正文>
  want=$1; body=$2
  if is_otp "$body"; then got=$(extract_code "$body"); else got=""; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'FAIL  期望[%s] 实得[%s]\n      正文: %s\n' "$want" "$got" "$body"
  fi
}

echo "== 应当命中 =="
check 123456 '【某某科技】您的验证码是 123456，5 分钟内有效。'
check 8842   '验证码：8842，请勿告知他人。'
check 917305 '您的动态码为917305，若非本人操作请忽略。'
check 4821   'Your verification code is 4821. It expires in 10 minutes.'
check 660214 '[GitHub] Your one-time code: 660214'
check 302914 'OTP 302914 for your login request'
check 5566   '您的校验码 5566 ，请在 5 分钟内输入。'

echo "== 多候选：必须挑关键词旁边那个，不是第一个数字 =="
# 「5 分钟」「400-820-8820 客服」都是数字陷阱
check 738291 '【银行】尊敬的客户，您本次操作的验证码为738291，5 分钟内有效，客服热线 4008208820。'
check 246810 '您有 3 条未读消息。验证码 246810 请勿转发。'
check 135790 '订单 20260728 已发货。取件验证码 135790。'

echo "== 不该命中（无关键词，纯数字不能乱抓）=="
check '' '您的快递 SF1234567890 已签收，感谢使用。'
check '' '本月账单 1280.00 元，请于 20260805 前缴纳。'
check '' '会议改到 14:30，房间 2058。'
check '' 'Your order 8829301 has shipped.'

echo "== 邮件路径：.emlx 首行是报文字节数，绝不能被当成验证码 =="
# 这条是真踩过的：首行长度头本身就是 4-8 位数字，不剥就会盖过每一封邮件的真码。
MAILROOT=$(mktemp -d)
MSGDIR="$MAILROOT/V10/ACCT/INBOX.mbox/Data/Messages"
mkdir -p "$MSGDIR"
CONF=$(mktemp)
printf 'MAIL_ROOT=%s\nSOURCES=mail\nNOTIFY=0\n' "$MAILROOT" > "$CONF"

mail_case() { # mail_case <期望码> <长度头> <正文>
  want=$1; prefix=$2; body=$3
  st=$(mktemp -d)
  OTP_CONF="$CONF" OTP_STATE_DIR="$st" sh "$DIR/otp.sh" --seed >/dev/null
  sleep 1
  printf '%s\nFrom: t@example.com\nSubject: code\nContent-Type: text/plain\n\n%s\n' \
    "$prefix" "$body" > "$MSGDIR/m.emlx"
  got=$(OTP_CONF="$CONF" OTP_STATE_DIR="$st" sh "$DIR/otp.sh" --dry-run \
        | sed -n 's/^\[dry-run\] 邮件 -> //p' | head -1)
  if [ "$got" = "$want" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'FAIL  期望[%s] 实得[%s]  长度头=%s\n' "$want" "$got" "$prefix"
  fi
  rm -rf "$st"
}
mail_case 903471 1234   'Your verification code is 903471. It expires in 10 minutes.'
mail_case 558102 104857 '【示例银行】您的验证码为 558102，5 分钟内有效，请勿转发。'
rm -rf "$MAILROOT" "$CONF"

echo
echo "通过 $pass / 失败 $fail"
rm -rf "$OTP_STATE_DIR"
[ "$fail" -eq 0 ]
