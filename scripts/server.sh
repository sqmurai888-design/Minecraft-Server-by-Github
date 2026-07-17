#!/usr/bin/env bash
# GitHub Actions 上で Minecraft サーバーを起動・公開・自動保存するスクリプト
set -euo pipefail

# ============================== 設定 ==============================
MC_VERSION="${MC_VERSION:-latest}"          # Minecraft バージョン
IDLE_TIMEOUT_MIN="${IDLE_TIMEOUT_MIN:-30}"  # 無人時の自動停止 (分, 0=無効)
AUTO_RESTART="${AUTO_RESTART:-true}"        # 6時間制限時に自動再起動するか
MAX_RUNTIME_MIN=330                         # 最大稼働時間 (GitHub の6時間制限より前に保存して止める)
BACKUP_INTERVAL_SEC=1200                    # 自動バックアップ間隔 (20分)
WORLD_BRANCH="world-data"                   # ワールド保存先ブランチ
STOP_BRANCH="stop-signal"                   # 停止シグナル用ブランチ

REPO_DIR="$GITHUB_WORKSPACE"
SERVER_DIR="${RUNNER_TEMP:-/tmp}/minecraft"
REMOTE="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
GIT_ID=(-c user.name=minecraft-server-bot -c user.email=actions@github.com)

mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"

log() { echo "[$(date -u '+%H:%M:%S')] $*"; }

# ============================== バージョン解決 & ダウンロード ==============================
# 通常はワークフローの resolve ステップ (scripts/resolve-version.sh) が
# SERVER_JAR_URL を渡してくる。ローカル実行時のみここで解決する。
if [ -z "${SERVER_JAR_URL:-}" ]; then
  log "Minecraft バージョンを解決しています..."
  MANIFEST=$(curl -fsSL "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")
  if [ "$MC_VERSION" = "latest" ] || [ -z "$MC_VERSION" ]; then
    MC_VERSION=$(echo "$MANIFEST" | jq -r '.latest.release')
  fi
  VERSION_URL=$(echo "$MANIFEST" | jq -r --arg v "$MC_VERSION" '.versions[] | select(.id == $v) | .url')
  if [ -z "$VERSION_URL" ] || [ "$VERSION_URL" = "null" ]; then
    echo "::error::バージョン '$MC_VERSION' が見つかりません。'latest' か正しいバージョン (例: 1.21.4) を指定してください。"
    exit 1
  fi
  SERVER_JAR_URL=$(curl -fsSL "$VERSION_URL" | jq -r '.downloads.server.url')
fi
log "Minecraft $MC_VERSION のサーバーをダウンロードしています..."
curl -fsSL -o server.jar "$SERVER_JAR_URL"

# ============================== ワールドデータの復元 ==============================
if git -C "$REPO_DIR" fetch origin "$WORLD_BRANCH" 2>/dev/null; then
  log "前回のワールドデータを '$WORLD_BRANCH' ブランチから復元しています..."
  git -C "$REPO_DIR" archive FETCH_HEAD | tar -x -C "$SERVER_DIR"
  rm -f SERVER_ADDRESS.txt
else
  log "保存済みワールドが見つかりません。新規ワールドを作成します。"
fi

# 古い停止シグナルが残っていたら消しておく
git -C "$REPO_DIR" push "$REMOTE" --delete "refs/heads/$STOP_BRANCH" 2>/dev/null || true

# ============================== サーバー設定 ==============================
echo "eula=true" > eula.txt
if [ -f "$REPO_DIR/config/server.properties" ]; then
  cp "$REPO_DIR/config/server.properties" server.properties
fi

# メモリはランナーの搭載量から自動計算 (2.5GB をシステム用に残す)
TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
XMX_MB=$(( TOTAL_MB - 2560 )); [ "$XMX_MB" -lt 2048 ] && XMX_MB=2048
log "メモリ割り当て: ${XMX_MB}MB"

# ============================== サーバー起動 ==============================
mkfifo console.in
exec 3<> console.in
send() { echo "$1" >&3; }

log "Minecraft サーバーを起動しています (初回はワールド生成に数分かかります)..."
java -Xms1024M -Xmx${XMX_MB}M -jar server.jar nogui <&3 > console.out 2>&1 &
JAVA_PID=$!
server_running() { kill -0 "$JAVA_PID" 2>/dev/null; }

READY=0
for _ in $(seq 1 120); do
  if ! server_running; then
    echo "::error::サーバーの起動に失敗しました。ログ末尾:"
    tail -50 console.out || true
    exit 1
  fi
  if grep -q 'Done (' logs/latest.log 2>/dev/null; then READY=1; break; fi
  sleep 5
done
if [ "$READY" != "1" ]; then
  echo "::error::サーバーが10分以内に起動しませんでした。"
  tail -50 console.out || true
  exit 1
fi
log "サーバー起動完了!"

# OP 権限の付与 (config/ops.txt に書かれたプレイヤー)
if [ -f "$REPO_DIR/config/ops.txt" ]; then
  grep -vE '^\s*(#|$)' "$REPO_DIR/config/ops.txt" | while read -r name; do
    log "OP 権限を付与: $name"
    send "op $name"
  done
fi

# ============================== トンネル (bore.pub) で公開 ==============================
log "トンネル (bore.pub) を開始しています..."
BORE_VERSION=$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
  "https://api.github.com/repos/ekzhang/bore/releases/latest" | jq -r '.tag_name' || true)
[ -z "$BORE_VERSION" ] || [ "$BORE_VERSION" = "null" ] && BORE_VERSION="v0.5.2"
curl -fsSL -o bore.tgz \
  "https://github.com/ekzhang/bore/releases/download/${BORE_VERSION}/bore-${BORE_VERSION}-x86_64-unknown-linux-musl.tar.gz"
tar xzf bore.tgz bore

start_tunnel() {
  ./bore local 25565 --to bore.pub > bore.log 2>&1 &
  BORE_PID=$!
}
start_tunnel

PORT=""
for _ in $(seq 1 30); do
  PORT=$(grep -oE 'bore\.pub:[0-9]+' bore.log | head -1 | cut -d: -f2 || true)
  [ -n "$PORT" ] && break
  sleep 2
done
if [ -z "$PORT" ]; then
  echo "::error::トンネルの確立に失敗しました。bore ログ:"
  cat bore.log || true
  send "stop"; sleep 15
  exit 1
fi
ADDRESS="bore.pub:$PORT"

BIG_LINE="=============================================="
echo "$BIG_LINE"
echo "  🎮 サーバーアドレス: $ADDRESS"
echo "$BIG_LINE"
{
  echo "# 🎮 Minecraft サーバー起動中!"
  echo ""
  echo "## サーバーアドレス"
  echo ""
  echo "# \`$ADDRESS\`"
  echo ""
  echo "マインクラフトの「マルチプレイ」→「サーバーを追加」で上のアドレスを入力してください。"
  echo ""
  echo "| 項目 | 値 |"
  echo "| --- | --- |"
  echo "| バージョン | $MC_VERSION |"
  echo "| 無人時の自動停止 | ${IDLE_TIMEOUT_MIN}分 |"
  echo "| 最大稼働時間 | 約5.5時間 (その後自動保存$( [ "$AUTO_RESTART" = "true" ] && echo "・自動再起動" )) |"
  echo ""
  echo "⚠️ アドレスは起動のたびに変わります。停止するには **🔴 Stop Minecraft Server** ワークフローを実行してください。"
} >> "$GITHUB_STEP_SUMMARY"

# ============================== バックアップ ==============================
do_world_save() {
  server_running || return 0
  local before
  before=$(wc -l < logs/latest.log)
  send "save-all flush"
  for _ in $(seq 1 30); do
    if tail -n +"$((before + 1))" logs/latest.log | grep -q 'Saved the game'; then break; fi
    sleep 2
  done
}

backup() { # $1 = SERVER_ADDRESS.txt に書く状態文字列
  [ -d world ] || return 0
  log "ワールドをバックアップしています..."
  server_running && send "save-off"
  do_world_save
  local bk
  bk=$(mktemp -d)
  rsync -a --exclude 'session.lock' world "$bk/"
  for f in ops.json whitelist.json banned-players.json banned-ips.json usercache.json server.properties; do
    [ -f "$f" ] && cp "$f" "$bk/" || true
  done
  server_running && send "save-on"
  echo "$1" > "$bk/SERVER_ADDRESS.txt"
  git -C "$bk" init -q -b "$WORLD_BRANCH"
  git -C "$bk" add -A
  git -C "$bk" "${GIT_ID[@]}" commit -qm "World backup: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  # 履歴を持たない単一コミットを強制 push (リポジトリの肥大化を防ぐ)
  git -C "$bk" push -f -q "$REMOTE" "$WORLD_BRANCH"
  rm -rf "$bk"
  log "バックアップ完了。"
}

backup "🟢 オンライン: $ADDRESS ($(date -u '+%Y-%m-%d %H:%M UTC') 起動)"

# ============================== メインループ ==============================
START_TS=$(date +%s)
LAST_ACTIVE=$START_TS
LAST_BACKUP=$START_TS
STOP_REASON=""

log "監視ループを開始します (停止: Stop ワークフロー / 無人${IDLE_TIMEOUT_MIN}分 / 最大${MAX_RUNTIME_MIN}分)"
while true; do
  sleep 30
  NOW=$(date +%s)

  if ! server_running; then
    STOP_REASON="crash"; break
  fi

  # トンネルが落ちていたら同じ設定で張り直す (ポートは変わる可能性あり)
  if ! kill -0 "$BORE_PID" 2>/dev/null; then
    log "トンネルが切断されました。再接続しています..."
    : > bore.log
    start_tunnel
    sleep 5
    NEW_PORT=$(grep -oE 'bore\.pub:[0-9]+' bore.log | head -1 | cut -d: -f2 || true)
    if [ -n "$NEW_PORT" ] && [ "$NEW_PORT" != "$PORT" ]; then
      PORT=$NEW_PORT; ADDRESS="bore.pub:$PORT"
      echo "## ⚠️ トンネル再接続 — 新アドレス: \`$ADDRESS\`" >> "$GITHUB_STEP_SUMMARY"
      log "新しいアドレス: $ADDRESS"
    fi
  fi

  # プレイヤー数 (ログの参加/退出から算出)
  JOINS=$(grep -c ' joined the game' logs/latest.log || true)
  LEAVES=$(grep -c ' left the game' logs/latest.log || true)
  ONLINE=$(( JOINS - LEAVES ))
  if [ "$ONLINE" -gt 0 ]; then LAST_ACTIVE=$NOW; fi

  if [ "$IDLE_TIMEOUT_MIN" -gt 0 ] && [ $(( NOW - LAST_ACTIVE )) -gt $(( IDLE_TIMEOUT_MIN * 60 )) ]; then
    STOP_REASON="idle"; break
  fi
  if git ls-remote --exit-code "$REMOTE" "refs/heads/$STOP_BRANCH" >/dev/null 2>&1; then
    STOP_REASON="manual"; break
  fi
  if [ $(( NOW - START_TS )) -gt $(( MAX_RUNTIME_MIN * 60 )) ]; then
    STOP_REASON="timeout"; break
  fi
  if [ $(( NOW - LAST_BACKUP )) -gt "$BACKUP_INTERVAL_SEC" ]; then
    backup "🟢 オンライン: $ADDRESS ($(date -u '+%Y-%m-%d %H:%M UTC') 時点)"
    LAST_BACKUP=$NOW
  fi
done

# ============================== シャットダウン ==============================
case "$STOP_REASON" in
  manual)  MSG="管理者によりサーバーが停止されます。ワールドは保存されます。" ;;
  idle)    MSG="プレイヤー不在のためサーバーを停止します。" ;;
  timeout) MSG="稼働時間の上限に達したため停止します。$( [ "$AUTO_RESTART" = "true" ] && echo "数分後に新しいアドレスで再起動します。" )" ;;
  crash)   MSG="" ;;
esac
log "停止処理を開始します (理由: $STOP_REASON)"

if server_running; then
  [ -n "$MSG" ] && send "say $MSG"
  sleep 5
  send "stop"
  for _ in $(seq 1 24); do
    server_running || break
    sleep 5
  done
  server_running && kill -9 "$JAVA_PID" 2>/dev/null || true
fi
kill "$BORE_PID" 2>/dev/null || true

backup "⚫ オフライン (最終保存: $(date -u '+%Y-%m-%d %H:%M UTC'))"
git -C "$REPO_DIR" push "$REMOTE" --delete "refs/heads/$STOP_BRANCH" 2>/dev/null || true

case "$STOP_REASON" in
  manual)  echo "## 🔴 Stop ワークフローによりサーバーを停止し、ワールドを保存しました。" >> "$GITHUB_STEP_SUMMARY" ;;
  idle)    echo "## 💤 ${IDLE_TIMEOUT_MIN}分間プレイヤーがいなかったため、自動停止しました (ワールドは保存済み)。" >> "$GITHUB_STEP_SUMMARY" ;;
  timeout) echo "## ⏰ 稼働時間の上限に達したため停止しました (ワールドは保存済み)。" >> "$GITHUB_STEP_SUMMARY" ;;
  crash)   echo "## 💥 サーバーが予期せず終了しました。最後のバックアップまでは保存されています。" >> "$GITHUB_STEP_SUMMARY"
           tail -50 console.out || true ;;
esac

# 6時間制限による停止なら、新しい実行を自動起動
if [ "$STOP_REASON" = "timeout" ] && [ "$AUTO_RESTART" = "true" ]; then
  log "サーバーを自動再起動しています..."
  curl -fsSL -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/start-server.yml/dispatches" \
    -d "{\"ref\":\"${GITHUB_REF_NAME}\",\"inputs\":{\"minecraft_version\":\"${MC_VERSION}\",\"idle_timeout\":\"${IDLE_TIMEOUT_MIN}\",\"auto_restart\":\"true\"}}" \
    && echo "## 🔄 新しいサーバーを起動しました。最新の実行のアドレスを確認してください。" >> "$GITHUB_STEP_SUMMARY" \
    || echo "::warning::自動再起動に失敗しました。手動で Start Minecraft Server を実行してください。"
fi

if [ "$STOP_REASON" = "crash" ]; then exit 1; fi
log "完了。"
