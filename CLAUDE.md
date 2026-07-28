# CLAUDE.md · otp-sh

macOS 验证码自动填充。单个 POSIX sh + launchd WatchPaths。自研,零依赖,不 import 总部代码。

## 这个项目的核心约束

**它的卖点就是「小」。任何增加常驻开销、依赖、或行数的改动都要先过这一关。**
前身 MessAuto 是 3232 行 Rust + 24 crate,空闲实测烧 87.9% 单核 ——
本项目存在的全部理由就是不重蹈那个覆辙。加东西之前先问:这真的必须常驻/必须引依赖吗。

- **禁引入任何第三方依赖**。只准用系统自带:`sqlite3` `plutil` `pbcopy` `osascript` `find` `grep` `sed`。
- **禁写常驻循环**。等待一律交给 launchd `WatchPaths`,不自己 poll、不自己 sleep-loop。
- **禁 `2>/dev/null`**。错误往 `$LOG` 写(铁律 #2 fail-closed)。哑掉的守卫和它要防的 bug 是同一类。

## 改抽取规则前必读

`extract_code` / `is_otp` 的现有形态是在**本机 238 条真实验证码短信上量出来的**,不是拍的。
三种写法比过,最简单那个赢了(详见 README 的表)。两个已经踩过的坑:

- 「只取关键词之后的数字」漏 21 条 —— 大量短信把码放在关键词**前面**(`418657为本次登录验证的手机验证码`)。
- 加宽泛反上下文词表误杀 5 条真码 —— `条` 命中「本条短信」、`账号` 命中「小米账号验证码」。

所以:**改规则必须先在真实语料上跑一遍再改**,别凭直觉「优化」。跑法:

```sh
# 用 otp.sh 里的真函数(不是重写一份 Python 版)跑真实库
eval "$(sed -n '/^KEYWORDS=/,/^}/p;/^extract_code()/,/^}/p' otp.sh)"
```

改完必跑 `./test/run.sh`(14 条),且新增规则要配**反向验证** —— 把该抓的 case 放回去确认真被拦下。

## TCC / 权限

权限记在实际 exec 的 Mach-O 上,shell 脚本没有独立 TCC 身份。
授权对象 = `~/.local/share/otp-sh/otp-shell`(`/bin/sh` 的私有 ad-hoc 签名副本)。
**别改成给系统 `/bin/sh` 授权** —— 那等于机器上任何 shell 脚本都能读全盘。

⚠️ **测权限前先确认开发机的 SIP 状态**(`csrutil status`)。SIP 关闭时 TCC 的文件保护
不按常规生效,「我这儿没授权也能读 chat.db」这类结论**在 SIP 开启的机器上不成立**。
关于权限的断言,开发机实测只是必要条件不是充分条件 —— 别把它当通用行为写进 README。

## 与 MessAuto 的关系

[MessAuto](https://github.com/LeeeSe/MessAuto) 是本项目的前身,但本项目不是它的分支,是独立重写。
两者**不能同时开启同一来源** —— 会重复填充/互相打架,迁移时先停掉 MessAuto。

## 状态与日志

- 状态:`~/.local/state/otp-sh/{sms.rowid,dingtalk.recid,mail.stamp}`
- 日志:`~/.local/state/otp-sh/otp.log`(自封顶 256KB,超了裁到最后 500 行)
- 首次安装会打基线(`--seed`),避免把历史消息当新验证码
