# MOD の入れ方

このフォルダに MOD の `.jar` ファイルを置いてコミットすると、次回起動時にサーバーへ読み込まれます。

## 手順

1. サーバーの種類に合った MOD をダウンロードする
   - [Modrinth](https://modrinth.com/mods) や [CurseForge](https://www.curseforge.com/minecraft/mc-mods) から入手できます
2. `.jar` ファイルをこの `mods/` フォルダにアップロード (コミット) する
3. **🟢 Start Minecraft Server** を実行するとき、「サーバーの種類」で `fabric` または `forge` を選ぶ

## 注意

- MOD が **Fabric 用か Forge 用か**、そして **Minecraft のバージョンが一致しているか**を確認してください
- 合わない MOD があっても大丈夫です — **その MOD だけ自動で外され、サーバーは残りの MOD で起動します**。外された MOD は起動した実行の Summary に表示されます
- 新しい要素 (ブロック・アイテムなど) を追加する MOD は、**参加する全員が自分の Minecraft にも同じ MOD を入れる**必要があります
- サーバー側だけで動く MOD (地形生成・最適化・管理系など) はクライアント側への導入は不要です
