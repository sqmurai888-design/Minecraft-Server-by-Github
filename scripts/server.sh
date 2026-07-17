#!/usr/bin/env bash
# GitHub Actions 上で Minecraft サーバーを起動・公開・自動保存するスクリプト
set -euo pipefail

# ============================== 設定 ==============================
MC_VERSION="${MC_VERSION:-latest}"          # Minecraft バージョン
SERVER_TYPE="${SERVER_TYPE:-vanilla}"       # vanilla / fabric / forge
IDLE_TIMEOUT_MIN="${IDLE_TIMEOUT_MIN:-30}"        # 無人時の自動停止 (分, 0=無効)
BACKUP_INTERVAL_MIN="${BACKUP_INTERVAL_MIN:-20}"  # 定期バックアップ間隔 (分, 0=無効)
AUTO_RESTART="${AUTO_RESTART:-true}"              # 6時間制限時に自動再起動するか
MAX_RUNTIME_MIN=330                               # 最大稼働時間 (GitHub の6時間制限より前に保存して止める)
WORLD_BRANCH="world-data"                   # ワールド保存先ブランチ
STOP_BRANCH="stop-signal"                   # 停止シグナル用ブランチ

REPO_DIR="$GITHUB_WORKSPACE"
SERVER_DIR="${RUNNER_TEMP:-/tmp}/minecraft"
REMOTE="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
GIT_ID=(-c user.name=minecraft-server-bot -c user.email=actions@github.com)

mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"

log() { echo "[$(date -u '+%H:%M:%S')] $*"; }

# ============================== バージョン解決 ==============================
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

# ============================== MOD の配置 ==============================
# 種類が合わない・壊れている MOD はスキップするだけで、サーバーの起動は妨げない
MOD_COUNT=0
SKIPPED_MODS=()
MODID_MAP="$SERVER_DIR/.modid_map"
: > "$MODID_MAP"

mod_loader_type() { # jar 内のメタデータから fabric / forge / unknown を判定
  if unzip -l "$1" 2>/dev/null | grep -q 'fabric\.mod\.json'; then echo fabric
  elif unzip -l "$1" 2>/dev/null | grep -qE 'META-INF/(neoforge\.)?mods\.toml|mcmod\.info'; then echo forge
  else echo unknown; fi
}

mod_id_of() { # jar から modid を取得 (取れなければ空)
  case "$(mod_loader_type "$1")" in
    fabric) unzip -p "$1" fabric.mod.json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true ;;
    forge)  unzip -p "$1" 'META-INF/*mods.toml' 2>/dev/null | grep -m1 -oE 'modId[[:space:]]*=[[:space:]]*"[^"]+"' | sed 's/.*"\(.*\)"/\1/' || true ;;
  esac
}

if compgen -G "$REPO_DIR/mods/*.jar" > /dev/null; then
  if [ "$SERVER_TYPE" = "vanilla" ]; then
    echo "::warning::mods/ に MOD がありますが、サーバーの種類が vanilla のため読み込まれません。fabric か forge を選んでください。"
  else
    mkdir -p mods
    rm -f mods/*.jar
    for jar in "$REPO_DIR"/mods/*.jar; do
      name=$(basename "$jar")
      ltype=$(mod_loader_type "$jar")
      if [ "$ltype" != "unknown" ] && [ "$ltype" != "$SERVER_TYPE" ]; then
        SKIPPED_MODS+=("$name — ${ltype} 用のため読み込みませんでした")
        echo "::warning::MOD をスキップ: $name は ${ltype} 用です (サーバーの種類: $SERVER_TYPE)"
        continue
      fi
      cp "$jar" mods/
      id=$(mod_id_of "$jar")
      [ -n "$id" ] && echo "$id $name" >> "$MODID_MAP"
    done
    MOD_COUNT=$(find mods -maxdepth 1 -name '*.jar' | wc -l)
    log "MOD を ${MOD_COUNT} 個配置しました (スキップ: ${#SKIPPED_MODS[@]} 個)"
  fi
fi

# メモリはランナーの搭載量から自動計算 (2.5GB をシステム用に残す)
TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
XMX_MB=$(( TOTAL_MB - 2560 )); [ "$XMX_MB" -lt 2048 ] && XMX_MB=2048
log "メモリ割り当て: ${XMX_MB}MB"

# ============================== サーバー本体の準備 ==============================
LAUNCH=()
case "$SERVER_TYPE" in
  vanilla)
    log "Minecraft $MC_VERSION (バニラ) をダウンロードしています..."
    curl -fsSL -o server.jar "$SERVER_JAR_URL"
    LAUNCH=(java -Xms1024M -Xmx${XMX_MB}M -jar server.jar nogui)
    ;;
  fabric)
    log "Fabric サーバー (Minecraft $MC_VERSION) を準備しています..."
    LOADER_META=$(curl -fsSL "https://meta.fabricmc.net/v2/versions/loader/$MC_VERSION")
    LOADER_VER=$(echo "$LOADER_META" | jq -r '[.[] | select(.loader.stable)][0].loader.version // .[0].loader.version // empty')
    if [ -z "$LOADER_VER" ]; then
      echo "::error::Minecraft $MC_VERSION に対応する Fabric がまだ提供されていません。対応バージョンは https://fabricmc.net/use/server/ で確認できます。"
      exit 1
    fi
    INSTALLER_VER=$(curl -fsSL "https://meta.fabricmc.net/v2/versions/installer" | jq -r '[.[] | select(.stable)][0].version // .[0].version')
    log "Fabric Loader $LOADER_VER をダウンロードしています..."
    curl -fsSL -o server.jar \
      "https://meta.fabricmc.net/v2/versions/loader/$MC_VERSION/$LOADER_VER/$INSTALLER_VER/server/jar"
    LAUNCH=(java -Xms1024M -Xmx${XMX_MB}M -jar server.jar nogui)
    ;;
  forge)
    log "Forge サーバー (Minecraft $MC_VERSION) を準備しています..."
    PROMOS=$(curl -fsSL "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json")
    FORGE_VER=$(echo "$PROMOS" | jq -r --arg k "$MC_VERSION-latest" '.promos[$k] // empty')
    if [ -z "$FORGE_VER" ]; then
      echo "::error::Minecraft $MC_VERSION に対応する Forge が見つかりません。対応バージョンは https://files.minecraftforge.net/ で確認できます。"
      exit 1
    fi
    log "Forge $FORGE_VER をインストールしています (数分かかります)..."
    curl -fsSL -o forge-installer.jar \
      "https://maven.minecraftforge.net/net/minecraftforge/forge/$MC_VERSION-$FORGE_VER/forge-$MC_VERSION-$FORGE_VER-installer.jar"
    if ! java -jar forge-installer.jar --installServer > forge-install.log 2>&1; then
      echo "::error::Forge のインストールに失敗しました。ログ末尾:"
      tail -30 forge-install.log || true
      exit 1
    fi
    if [ -f run.sh ]; then
      # 新しい Forge (1.17+): run.sh 経由で起動し、メモリは user_jvm_args.txt で指定
      printf -- "-Xms1024M\n-Xmx%sM\n" "$XMX_MB" > user_jvm_args.txt
      chmod +x run.sh
      LAUNCH=(./run.sh nogui)
    else
      # 古い Forge: forge-*.jar を直接起動
      FORGE_JAR=$(find . -maxdepth 1 -name "forge-*.jar" ! -name "*installer*" | head -1)
      LAUNCH=(java -Xms1024M -Xmx${XMX_MB}M -jar "$FORGE_JAR" nogui)
    fi
    ;;
  *)
    echo "::error::不明なサーバー種類 '$SERVER_TYPE' です (vanilla / fabric / forge)。"
    exit 1
    ;;
esac

# ============================== サーバー起動 ==============================
mkfifo console.in
exec 3<> console.in
send() { echo "$1" >&3; }
server_running() { kill -0 "$JAVA_PID" 2>/dev/null; }

start_attempt() { # 0=起動成功 / 1=プロセスが起動前に終了 / 2=タイムアウト
  rm -f logs/latest.log console.out
  "${LAUNCH[@]}" <&3 > console.out 2>&1 &
  JAVA_PID=$!
  for _ in $(seq 1 120); do
    server_running || return 1
    grep -q 'Done (' logs/latest.log 2>/dev/null && return 0
    sleep 5
  done
  return 2
}

remove_incompatible_mods() { # 起動ログから原因の MOD を特定して無効化。0=特定できた / 1=特定できず
  local ids id file removed=1
  ids=$( { grep -ahoE "Mod '[^']+' \([A-Za-z0-9_.-]+\)" console.out logs/latest.log 2>/dev/null \
            | grep -oE '\([A-Za-z0-9_.-]+\)' | tr -d '()';
           grep -ahoE "Mod ID: '[A-Za-z0-9_.-]+'" console.out logs/latest.log 2>/dev/null \
            | grep -oE "'[A-Za-z0-9_.-]+'" | tr -d "'"; } | sort -u || true)
  for id in $ids; do
    file=$(awk -v id="$id" '$1==id {print $2; exit}' "$MODID_MAP" || true)
    if [ -n "$file" ] && [ -f "mods/$file" ]; then
      rm -f "mods/$file"
      SKIPPED_MODS+=("$file — このバージョン/構成と互換性がないため無効化しました")
      echo "::warning::互換性のない MOD を無効化して再起動します: $file"
      removed=0
    fi
  done
  return $removed
}

log "Minecraft サーバーを起動しています (初回はワールド生成に数分かかります)..."
ATTEMPT=1
while true; do
  RC=0; start_attempt || RC=$?
  if [ "$RC" -eq 0 ]; then break; fi
  if [ "$RC" -eq 2 ]; then
    echo "::error::サーバーが10分以内に起動しませんでした。"
    tail -50 console.out || true
    exit 1
  fi
  # 起動前にプロセスが終了 → MOD が原因なら外して再試行 (ワールドには必ず入れるようにする)
  ACTIVE_MODS=$(find mods -maxdepth 1 -name '*.jar' 2>/dev/null | wc -l)
  if [ "$SERVER_TYPE" != "vanilla" ] && [ "$ACTIVE_MODS" -gt 0 ] && [ "$ATTEMPT" -lt 3 ]; then
    log "起動に失敗しました。原因の MOD を調べています..."
    if ! remove_incompatible_mods; then
      log "原因の MOD を特定できなかったため、すべての MOD を無効化して起動します。"
      echo "::warning::起動失敗の原因を特定できなかったため、すべての MOD を無効化して起動します。"
      for f in mods/*.jar; do
        [ -f "$f" ] && SKIPPED_MODS+=("$(basename "$f") — 起動失敗のため無効化しました")
      done
      rm -f mods/*.jar
    fi
    ATTEMPT=$(( ATTEMPT + 1 ))
    continue
  fi
  echo "::error::サーバーの起動に失敗しました。ログ末尾:"
  tail -50 console.out || true
  exit 1
done
MOD_COUNT=$(find mods -maxdepth 1 -name '*.jar' 2>/dev/null | wc -l)
log "サーバー起動完了!"

# OP 権限の付与 (config/ops.txt に書かれたプレイヤー)
if [ -f "$REPO_DIR/config/ops.txt" ]; then
  while read -r name; do
    [ -n "$name" ] || continue
    log "OP 権限を付与: $name"
    send "op $name"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO_DIR/config/ops.txt" || true)
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
  echo "| バージョン | $MC_VERSION ($SERVER_TYPE) |"
  if [ "$MOD_COUNT" -gt 0 ] || [ "${#SKIPPED_MODS[@]}" -gt 0 ]; then
    echo "| MOD | 有効 ${MOD_COUNT}個 / 無効 ${#SKIPPED_MODS[@]}個 |"
  fi
  echo "| 無人時の自動停止 | ${IDLE_TIMEOUT_MIN}分 |"
  echo "| ワールド保存 | ${BACKUP_INTERVAL_MIN}分ごと + 全員退出時 + 停止時 |"
  echo "| 最大稼働時間 | 約5.5時間 (その後自動保存$( [ "$AUTO_RESTART" = "true" ] && echo "・自動再起動" )) |"
  echo ""
  echo "⚠️ アドレスは起動のたびに変わります。停止するには **🔴 Stop Minecraft Server** ワークフローを実行してください。"
  if [ "${#SKIPPED_MODS[@]}" -gt 0 ]; then
    echo ""
    echo "### ⚠️ 読み込まれなかった MOD (サーバーは MOD なしの部分も含めて起動しています)"
    for m in "${SKIPPED_MODS[@]}"; do echo "- $m"; done
  fi
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
  # MOD が生成する設定ディレクトリも保存 (fabric/forge)
  for d in config defaultconfigs; do
    [ -d "$d" ] && rsync -a "$d" "$bk/" || true
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
PREV_ONLINE=0
STOP_REASON=""

log "監視ループを開始します (停止: Stop ワークフロー / 無人${IDLE_TIMEOUT_MIN}分 / 定期バックアップ${BACKUP_INTERVAL_MIN}分ごと / 最大${MAX_RUNTIME_MIN}分)"
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

  # 全員が退出した瞬間に即バックアップ (プレイ内容を確実に残す)
  if [ "$PREV_ONLINE" -gt 0 ] && [ "$ONLINE" -le 0 ]; then
    log "全プレイヤーが退出しました。ワールドを保存します..."
    backup "🟢 オンライン: $ADDRESS ($(date -u '+%Y-%m-%d %H:%M UTC') 全員退出時に保存)"
    LAST_BACKUP=$NOW
  fi
  PREV_ONLINE=$ONLINE

  if [ "$IDLE_TIMEOUT_MIN" -gt 0 ] && [ $(( NOW - LAST_ACTIVE )) -gt $(( IDLE_TIMEOUT_MIN * 60 )) ]; then
    STOP_REASON="idle"; break
  fi
  if git ls-remote --exit-code "$REMOTE" "refs/heads/$STOP_BRANCH" >/dev/null 2>&1; then
    STOP_REASON="manual"; break
  fi
  if [ $(( NOW - START_TS )) -gt $(( MAX_RUNTIME_MIN * 60 )) ]; then
    STOP_REASON="timeout"; break
  fi
  if [ "$BACKUP_INTERVAL_MIN" -gt 0 ] && [ $(( NOW - LAST_BACKUP )) -gt $(( BACKUP_INTERVAL_MIN * 60 )) ]; then
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
    -d "{\"ref\":\"${GITHUB_REF_NAME}\",\"inputs\":{\"minecraft_version\":\"${MC_VERSION}\",\"server_type\":\"${SERVER_TYPE}\",\"idle_timeout\":\"${IDLE_TIMEOUT_MIN}\",\"backup_interval\":\"${BACKUP_INTERVAL_MIN}\",\"auto_restart\":\"true\"}}" \
    && echo "## 🔄 新しいサーバーを起動しました。最新の実行のアドレスを確認してください。" >> "$GITHUB_STEP_SUMMARY" \
    || echo "::warning::自動再起動に失敗しました。手動で Start Minecraft Server を実行してください。"
fi

if [ "$STOP_REASON" = "crash" ]; then exit 1; fi
log "完了。"
