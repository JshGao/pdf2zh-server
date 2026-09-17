#!/bin/zsh
# Acceptance checks for PDF2ZH Web. See VIBE_CODING.md §9.
#
#   ./scripts/verify.sh
#
# Checks, in order:
#   1. bundle structure, Info.plist (LSUIElement), signature, icon artefacts
#   2. runtime: the app launches both services, the ports answer, the logs are private
#   3. teardown: the app stops both services and leaves no processes behind
#
# The Zotero service (zotero-pdf2zh's server.py) is optional: its checks are skipped when
# server.py is not installed.
#
# The script starts the app if it is not already running, and leaves it stopped.
set -uo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PDF2ZH Web"
APP_DIR="$SRC_DIR/build/$APP_NAME.app"
EXEC_NAME="PDF2ZHWebMenuBar"
PORT="${PDF2ZH_WEB_PORT:-7860}"
LOG_PATH="${PDF2ZH_LOG_PATH:-$HOME/Library/Logs/pdf2zh-web.log}"
ZOTERO_PORT="${PDF2ZH_ZOTERO_PORT:-8890}"
ZOTERO_LOG="${PDF2ZH_ZOTERO_LOG:-$HOME/Library/Logs/pdf2zh-zotero.log}"
ZOTERO_SERVER="${PDF2ZH_ZOTERO_SERVER:-$HOME/zotero-pdf2zh/server/server.py}"
SUPPORT_DIR="$HOME/Library/Application Support/PDF2ZHWeb"

failures=0
pass() { print -r -- "  ✓ $1" }
fail() { print -r -- "  ✗ $1"; failures=$((failures + 1)) }
section() { print -r -- ""; print -r -- "$1" }

wait_for() {
  # wait_for <seconds> <command...>
  local seconds="$1"; shift
  local i
  for i in $(seq 1 "$seconds"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

# Print whatever would explain a failure to start. Safe to call when everything worked:
# it only emits when a log actually exists. Truncated because CI logs are easier to scan
# than they are to scroll.
dump_diagnostics() {
  print -r -- ""
  print -r -- "  ---- 诊断信息（供 CI 排查）----"
  for f in "$LOG_PATH" "$SUPPORT_DIR/config.json"; do
    if [[ -f "$f" ]]; then
      print -r -- "  [文件] $f"
      tail -30 "$f" 2>/dev/null | sed 's/^/    | /'
    else
      print -r -- "  [缺失] $f"
    fi
  done
  print -r -- "  [自检] pdf2zh_next 能否执行："
  local exe
  exe="$(python3 -c "
import json,sys
try:
    print(json.load(open('$SUPPORT_DIR/config.json')).get('pdf2zhPath',''))
except Exception:
    print('')
" 2>/dev/null)"
  if [[ -n "$exe" && -x "$exe" ]]; then
    print -r -- "    路径: $exe"
    "$exe" --version 2>&1 | tail -5 | sed 's/^/    | /'
  else
    print -r -- "    未找到可执行文件（config 中 pdf2zhPath='$exe'）"
  fi
  print -r -- "  ------------------------------"
}

app_running() { pgrep -f "$EXEC_NAME" >/dev/null 2>&1; }
port_listening() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; }
service_running() { pgrep -f "pdf2zh_next.*--gui" >/dev/null 2>&1; }
zotero_port_listening() { lsof -nP -iTCP:"$ZOTERO_PORT" -sTCP:LISTEN >/dev/null 2>&1; }
zotero_running() { pgrep -f "server.py --port" >/dev/null 2>&1; }
# The Zotero service is optional: only check it when server.py is actually installed.
zotero_expected() { [[ -r "$ZOTERO_SERVER" ]]; }

# ---------------------------------------------------------------- 1. bundle
section "1. bundle 结构"
if [[ -d "$APP_DIR" ]]; then
  pass "存在 $APP_DIR"
else
  fail "缺少 $APP_DIR（先运行 ./build.sh）"
  print -r -- ""; print -r -- "验收失败： 项"
  exit 1
fi

for relative in \
  "Contents/MacOS/$EXEC_NAME" \
  "Contents/Info.plist" \
  "Contents/Resources/pdf2zh-status.png" \
  "Contents/Resources/AppIcon.icns"
do
  if [[ -e "$APP_DIR/$relative" ]]; then
    pass "包含 $relative"
  else
    fail "缺少 $relative"
  fi
done

if [[ -x "$APP_DIR/Contents/MacOS/$EXEC_NAME" ]]; then
  pass "可执行文件有执行权限"
else
  fail "可执行文件缺少执行权限"
fi

PLIST="$APP_DIR/Contents/Info.plist"
if plutil -lint "$PLIST" >/dev/null 2>&1; then
  pass "Info.plist 格式合法"
else
  fail "Info.plist 格式非法"
fi

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST" 2>/dev/null)" == "true" ]]; then
  pass "LSUIElement=true（不占程序坞、不进 Cmd-Tab）"
else
  fail "LSUIElement 不是 true"
fi

if codesign --verify --strict "$APP_DIR" >/dev/null 2>&1; then
  pass "签名校验通过（ad-hoc）"
else
  fail "签名校验失败"
fi

# 图标必须是黑字 + 透明背景，否则 isTemplate 上色后不可见。
STATUS_ICON="$APP_DIR/Contents/Resources/pdf2zh-status.png"
if [[ -f "$STATUS_ICON" ]] && sips -g hasAlpha "$STATUS_ICON" 2>/dev/null | grep -q "hasAlpha: yes"; then
  pass "状态栏图标带 alpha 通道（可作模板图）"
else
  fail "状态栏图标缺少 alpha 通道"
fi

# ---------------------------------------------------------------- 2. runtime
section "2. 运行期"
started_by_us=0
if app_running; then
  pass "App 已在运行，执行运行期检查"
else
  print -r -- "  启动 $APP_NAME …"
  if ! open "$APP_DIR"; then
    fail "无法启动 App"
  fi
  started_by_us=1
fi

if wait_for 8 app_running; then
  pass "App 进程存在"
else
  fail "App 进程未出现"
fi

if wait_for 60 port_listening; then
  pass "端口 $PORT 正在监听"
else
  fail "60 秒内端口 $PORT 未监听（看日志：$LOG_PATH）"
  # Without this the failure is invisible on CI, where the runner's disk disappears with the
  # job: "port never opened" is a symptom, and the cause is always in one of these.
  dump_diagnostics
fi

if wait_for 10 service_running; then
  pass "pdf2zh_next 服务进程存在"
else
  fail "未找到 pdf2zh_next 服务进程"
fi

if port_listening; then
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)"
  if [[ "$code" == "200" ]]; then
    pass "WebUI 返回 HTTP 200（无需 token，可直接访问）"
  else
    fail "WebUI 返回 HTTP $code"
  fi
fi

if [[ -f "$LOG_PATH" ]]; then
  permissions="$(stat -f '%Lp' "$LOG_PATH" 2>/dev/null)"
  if [[ "$permissions" == "600" ]]; then
    pass "日志权限为 0600"
  else
    fail "日志权限为 $permissions，应为 600"
  fi
else
  fail "日志文件不存在：$LOG_PATH"
fi

if [[ -f "$SUPPORT_DIR/config.json" ]]; then
  pass "配置模板已生成：$SUPPORT_DIR/config.json"
else
  fail "配置模板未生成"
fi

if zotero_expected; then
  if wait_for 90 zotero_port_listening; then
    pass "Zotero 服务端口 $ZOTERO_PORT 正在监听"
  else
    fail "90 秒内端口 $ZOTERO_PORT 未监听（看日志：$ZOTERO_LOG）"
  fi
  if zotero_port_listening; then
    health="$(curl -s --max-time 5 "http://127.0.0.1:$ZOTERO_PORT/health" 2>/dev/null)"
    if [[ "$health" == *"PDF2zh Server is running"* ]]; then
      pass "Zotero /health 返回正确标识（插件就是靠这句识别服务）"
    else
      fail "Zotero /health 未返回预期内容：${health:0:80}"
    fi
  fi
  if [[ -f "$ZOTERO_LOG" ]]; then
    zperm="$(stat -f '%Lp' "$ZOTERO_LOG" 2>/dev/null)"
    if [[ "$zperm" == "600" ]]; then
      pass "Zotero 服务日志权限为 0600"
    else
      fail "Zotero 服务日志权限为 $zperm，应为 600"
    fi
  fi
else
  pass "未安装 server.py，跳过 Zotero 服务检查（$ZOTERO_SERVER）"
fi

# ---------------------------------------------------------------- 3. teardown
section "3. 退出清理"
if app_running; then
  print -r -- "  退出 App …"
  pkill -TERM -x "$EXEC_NAME" >/dev/null 2>&1
else
  pass "App 已不在运行"
fi

if wait_for 8 bash -c "! pgrep -f '$EXEC_NAME' >/dev/null 2>&1"; then
  pass "App 进程已退出"
else
  fail "App 进程仍在"
fi

if wait_for 12 bash -c "! lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1"; then
  pass "端口 $PORT 已释放"
else
  fail "端口 $PORT 仍被占用"
fi

# 看门狗有 3 秒宽限期，给它时间收尾再判定残留。
wait_for 12 bash -c "! pgrep -f 'pdf2zh_next.*--gui' >/dev/null 2>&1" >/dev/null 2>&1
if service_running; then
  fail "仍有 pdf2zh_next 残留进程"
  pgrep -fl "pdf2zh_next" | head -5
else
  pass "无 pdf2zh_next 残留进程"
fi

if pgrep -f "$EXEC_NAME" >/dev/null 2>&1; then
  fail "App 仍有残留进程"
else
  pass "无 App 残留进程"
fi

if zotero_expected; then
  if wait_for 12 bash -c "! lsof -nP -iTCP:$ZOTERO_PORT -sTCP:LISTEN >/dev/null 2>&1"; then
    pass "Zotero 服务端口 $ZOTERO_PORT 已释放"
  else
    fail "Zotero 服务端口 $ZOTERO_PORT 仍被占用"
  fi
  wait_for 12 bash -c "! pgrep -f 'server.py --port' >/dev/null 2>&1" >/dev/null 2>&1
  if zotero_running; then
    fail "仍有 zotero server 残留进程"
  else
    pass "无 zotero server 残留进程"
  fi
fi

if [[ "$started_by_us" == "1" ]]; then
  print -r -- ""; print -r -- "  （App 由本次验收启动，现已退出）"
fi

# ---------------------------------------------------------------- summary
section "结果"
if [[ "$failures" == "0" ]]; then
  print -r -- "全部通过 ✓"
  exit 0
else
  print -r -- "失败 $failures 项 ✗"
  exit 1
fi
