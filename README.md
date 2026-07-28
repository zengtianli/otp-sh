# otp-sh

macOS one-time-passcode autofill in **one shell script**. Event-driven — no process exists while idle.

English · [中文](README.zh-CN.md)

Verification codes from SMS / DingTalk / Mail land in your clipboard the moment they arrive. No resident daemon, no polling loop, no menu-bar icon, no third-party dependency.

```
idle:      0 processes   0 MB RAM   0% CPU
on event:  woken in 0.3s, runs for 0.16s, exits
```

## Why this exists

The predecessor is [MessAuto](https://github.com/LeeeSe/MessAuto) (Rust, 3232 lines, 24 dependencies). It does the right thing, but the cost of staying resident got caught red-handed on my M4:

| | MessAuto 1.3.0 | otp-sh |
|---|---|---|
| Idle CPU | **87.9% of a core** (measured, 30s delta) | 0% (no process) |
| Burned so far | 1514 min user CPU over 37h uptime | — |
| Resident memory | 19 MB | 0 |
| Resident threads | 21 (15 tokio workers + 2 fsevents loops) | 0 |
| Code | 3232 lines of Rust | 216 lines of POSIX sh |
| Dependencies | 24 crates | 0 |

That 87.9% is not by design — it is a bug. `sample` caught 3005 out of 3005 frames in one stack:

```
FileWatcher<EmailProcessor>::start → EmailProcessor::process_file
  → email::MimeMessage::parse → Rfc5322Parser::consume_header
      → consume_unstructured   2215 frames
      → peek_linebreak          790 frames
```

The `email` crate (0.0.21, published 2016) cannot get out of its RFC5322 header parser on some `.emlx`. Worse: `process_file` is called **synchronously** inside the watch loop, so from the moment it wedged, the entire Mail path was dead — silently broken while pinning a core.

The lesson isn't "that bug should be fixed". It's this: **extracting six digits out of three SQLite databases and some plaintext files does not require a resident multi-threaded runtime with a MIME parser.** It is `sqlite3` and `grep`.

## What it actually costs per day

"0 while idle" is true but incomplete — the question that matters is **total burn per day**.
One run costs **129 ms of CPU** (mean of 30 runs via `rusage`), peaking at 3.6 MB RSS.
Multiply by wake count:

| Scenario | Wakes/day | CPU-sec/day | % of one core | Basis |
|---|---|---|---|---|
| **Measured** | 74 | 9.5 | 0.011% | 1 natural wake in a 19.5-min window, extrapolated |
| Heavy chat day | 500 | 64.5 | 0.075% | assume 500 write events |
| **Hard ceiling** | **8640** | **1115** | **1.29%** | launchd throttles to ≥10s/run |
| MessAuto, for contrast | — | **75946** | **87.9%** | resident, measured |

**Even pinned at launchd's maximum firing rate, otp-sh burns 1115 CPU-seconds a day. MessAuto reaches that figure in 21 minutes.**

The measured row extrapolates from a 19.5-minute quiet window, which is not rigorous — wakes are bursty, not uniform.
But it sits 117× below the ceiling, so wherever the true figure lands, the conclusion is unchanged.

## How it works

launchd's `WatchPaths` wakes a job when a watched file is written. So there is no watch loop to write — **the kernel does the waiting**.

```
SMS arrives → macOS writes chat.db-wal → launchd wakes job (0.30s measured) → otp.sh runs 0.16s → exits
```

Three sources, one job, one state dir:

| Source | Reads | Method |
|---|---|---|
| Messages / iMessage | `~/Library/Messages/chat.db` | `sqlite3`, incremental by ROWID |
| DingTalk | `~/Library/Group Containers/group.com.apple.usernoted/db2/db` | `sqlite3` notification BLOB → `plutil -extract req.body` |
| Mail | `~/Library/Mail/V*/*/INBOX.mbox` | `find -newer` + read plaintext (`.emlx` *is* plaintext — no MIME parser needed) |

## The extraction rule was measured, not guessed

Three variants, compared over 238 real verification-code messages. The result is counter-intuitive:

| Rule | Outcome |
|---|---|
| **Keyword gate + first 4–8 digit run** | 238/238 extracted, 0 verifiable mispicks ← adopted |
| Only take digits *after* the keyword | Misses 21. Many messages put the code first: `418657为本次登录验证的手机验证码` |
| Broad anti-context word list | Kills 5 real codes. `条` matched "本条短信", `账号` matched "小米账号验证码" |

The simplest one won. Only one narrow mask is kept — digits immediately following `尾号|订单|客服电话` (card suffix / order no. / hotline) are blanked first. That mask fires 0 times across the 238 real messages; it is insurance for shapes like `订单 20260728 已发货，取件验证码 135790`.

Run `./test/run.sh` for the 16 regression cases.

## Install

```sh
git clone <repo> && cd otp-sh
./install.sh
```

Then do the one thing only you can do: add `~/.local/share/otp-sh/otp-shell` to **Full Disk Access** (the installer opens the pane for you).

**Why `otp-shell` and not `otp.sh`**: macOS TCC attributes permissions to the Mach-O that is actually exec'd — a script has no identity of its own. A `#!/bin/sh` script's TCC identity is `/bin/sh`. Granting Full Disk Access to the system `/bin/sh` would let *every* shell script on the machine read your whole disk. So the installer copies `sh`, ad-hoc signs the copy, and you grant only that copy — blast radius is this tool alone.

Verify:

```sh
~/.local/share/otp-sh/otp-shell ~/.local/share/otp-sh/otp.sh --dry-run
```

Uninstall: `./install.sh --uninstall`

## Configure

`~/.config/otp-sh/config` — plain sh assignments:

```sh
MAX_AGE=180                    # seconds; anything older is ignored
SOURCES="sms dingtalk mail"    # drop what you don't want
AUTO_TYPE=0                    # 1 = type the code (needs Accessibility)
AUTO_ENTER=0                   # 1 = press Return after typing
NOTIFY=1                       # 1 = post a notification
```

`MAX_AGE` is not optional garnish: launchd throttles a job to once per 10s under a burst, and jobs can run late or catch up. Without an age ceiling, a catch-up run would quietly drop an hours-old code into your clipboard.

## Known limits

- **launchd throttling** — under continuous writes a job runs at most once per 10s. Isolated events respond in 0.3s; the 10s worst case only applies if a code arrives while you're mid-conversation.
- **Codes must carry a keyword** (验证码 / code / OTP / …). A bare `123456` with no context is ignored on purpose — otherwise order numbers, amounts and room numbers all get grabbed.
- **Inbox only** — archives and junk are not scanned.
- **Mail is read as plaintext**, so base64-encoded bodies are missed. Nearly all OTP mail carries a `text/plain` part, so this rarely bites. Covering it would require a MIME parser — which is precisely what got replaced.

## License

MIT
