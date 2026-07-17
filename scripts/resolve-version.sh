#!/usr/bin/env bash
# Minecraft のバージョンを解決し、サーバー jar の URL と必要な Java バージョンを出力する
set -euo pipefail

MC_VERSION="${MC_VERSION:-latest}"

echo "Minecraft バージョンを解決しています..."
MANIFEST=$(curl -fsSL "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")
if [ "$MC_VERSION" = "latest" ] || [ -z "$MC_VERSION" ]; then
  MC_VERSION=$(echo "$MANIFEST" | jq -r '.latest.release')
fi

VERSION_URL=$(echo "$MANIFEST" | jq -r --arg v "$MC_VERSION" '.versions[] | select(.id == $v) | .url')
if [ -z "$VERSION_URL" ] || [ "$VERSION_URL" = "null" ]; then
  echo "::error::バージョン '$MC_VERSION' が見つかりません。'latest' か正しいバージョン (例: 1.21.4) を指定してください。"
  exit 1
fi

VERSION_JSON=$(curl -fsSL "$VERSION_URL")
SERVER_JAR_URL=$(echo "$VERSION_JSON" | jq -r '.downloads.server.url // empty')
if [ -z "$SERVER_JAR_URL" ]; then
  echo "::error::バージョン '$MC_VERSION' にはサーバー版が提供されていません。"
  exit 1
fi

# Mojang が指定する必要 Java バージョン (古いバージョンには情報がないので 8 を既定に)
JAVA_VERSION=$(echo "$VERSION_JSON" | jq -r '.javaVersion.majorVersion // 8')

echo "Minecraft: $MC_VERSION / 必要な Java: $JAVA_VERSION"
{
  echo "mc_version=$MC_VERSION"
  echo "java_version=$JAVA_VERSION"
  echo "server_jar_url=$SERVER_JAR_URL"
} >> "$GITHUB_OUTPUT"
