# Obsidian 同步方案升级参考（Syncthing vs LiveSync）

> 状态: **参考文档（未实施）** · 2026-08-10
> 用途: 评估是否将 vault 同步从 Self-hosted LiveSync 迁移到 Syncthing 的决策记录

---

## 1. 背景与动机

**痛点**：LiveSync（CouchDB 多主双向同步）**无权威仲裁**——服务器删除的文档（tombstone）可被离线的客户端在重新上线后"续写"复活（CouchDB 修订树允许删除后重建）。本项目实际踩坑：Windows 客户端在服务器清理后把 33 个已删除文件重新上传。

**期望**：服务器权威 + 删除最终化 + 版本可恢复 + 服务器脚本简化。

---

## 2. 方案对比总表

| 维度 | **LiveSync**（现用） | **Syncthing** |
|------|---------------------|---------------|
| 同步模型 | CouchDB 文档数据库，多主双向 | 文件级 P2P 双向，**全局状态向量**（version vector）协调 |
| 删除传播 | ❌ tombstone 可被"续写"复活 | ✅ 删除作为状态变更传播，**离线设备上线后接受删除**（不复活）|
| 冲突仲裁 | ❌ 无自动仲裁（需插件逻辑/手动）| 🟡 冲突时保留 `.sync-conflict-*` 双方副本（不丢数据，人工合并）|
| 版本历史 | ❌ 无 | ✅ **内置文件版本控制**（trash-can/simple/staggered），误删/覆盖可恢复 |
| 实时性 | 秒级（changes 长轮询）| 秒级（设备在线时）|
| 服务器脚本集成 | ❌ 私有格式（plain/leaf/分块），需转换层 | ✅ **纯文件系统**，llmwiki 直接读写，脚本退化为文件操作 |
| 服务器依赖 | 强依赖 CouchDB（单点）| 去中心化，服务器只是节点之一 |
| 安全 | ⚠️ 当前 5984 公网明文暴露 | ✅ 端到端 TLS，无需暴露端口（走中继/发现服务）|
| 数据可移植性 | ❌ 锁在 CouchDB | ✅ vault 即文件 |
| 数据库膨胀 | ❌ tombstone/孤儿块需定期清理 | ✅ 无此问题 |
| 运维复杂度 | CouchDB 单服务 | 每设备装 Syncthing + 设备配对 + 文件夹共享 |
| 成熟度 | 11.9k ⭐，活跃 | 87.5k ⭐，极成熟活跃 |
| 多用户 | 单凭据（共享 admin 密码）| 设备 ID 天然多用户 |

**Syncthing 相对优势**：删除传播 ✅ / 版本恢复 ✅ / 文件即文件 ✅ / 安全 ✅ / 去中心化 ✅ / 多用户 ✅

---

## 3. iPhone 端差距细节（唯一明显短板）

iOS 无官方 Syncthing app，唯一广泛可用的是 **Möbius Sync**（$4.99 一次性买断，免费版仅 20MB 试玩）：

| 项 | LiveSync | Syncthing (Möbius Sync) |
|----|----------|------------------------|
| 客户端 | Obsidian 插件内嵌，打开 Obsidian 即同步 | 独立 app，多一层依赖 |
| 接入方式 | 插件填服务器地址 | 需"外部文件夹"接入 Obsidian 沙盒（建临时 vault → Möbius 共享外部目录 → Obsidian 打开），一次性配置繁琐 |
| iOS 兼容性 | 成熟稳定 | **iOS 18.x 已知 bug**（MobiusSync issue #222：部分设备 `.stignore` 报错，有 workaround 但不保证）|
| 后台同步 | 随 Obsidian 运行 | iOS 后台限制，**需定期打开 app 才同步** |

**核心区别**：LiveSync 是"Obsidian 的一部分"；Syncthing 在 iPhone 上是"两个 app 的合作"，而 iOS 的沙盒/后台限制恰好让这层最脆弱。

---

## 4. 决策框架

| 使用模式 | 建议 |
|---------|------|
| iPhone 主力写作/采集 | **不换**：LiveSync + 镜像强制补删除短板（见 §5.2）|
| iPhone 只读/偶尔查看 | **换 Syncthing**：收益（删除/版本/安全/脚本简化）远超 iPhone 妥协 |
| 不确定 | 双轨试点：腾讯云 Syncthing 先同步测试 vault，用一周感受 iPhone 端 |

---

## 5. 迁移方案要点（若实施）

### 5.1 Syncthing 部署形态

```
各设备 (Mac/Windows/iPhone-Möbius) ⟷ 腾讯云 Syncthing 节点 ⟷ /opt/obsidian-vault/
                                                              │
                                    llmwiki 直接读写该目录（raw/ + wiki/）
```

- 腾讯云：安装 Syncthing 节点，共享文件夹指向 `/opt/obsidian-vault/`
- 服务器脚本：`sync-vault-raw.sh` / `sync-wiki-push.sh` **退役**（无需 CouchDB 格式转换）
- llmwiki：`sources/` 与 `wiki/` 直接改为 vault 内的 `raw/`、`wiki/` 目录
- 建议开启 Syncthing **staggered 版本控制**（防误删/覆盖）
- 现有 LiveSync 流水线保留到迁移验证完成后再下线

### 5.2 若不迁移：LiveSync 补强（镜像强制）

当前 `sync-wiki-push.sh` 删除同步只清"服务器推过且消失"的文件，管不住客户端上传的"多余"文件。升级为**全量镜像**：

```
每 30s:
  1. 服务器 wiki/ 文件 → 推送到 CouchDB（现有逻辑）
  2. 扫描 CouchDB 所有 wiki/ 存活文档
  3. 不在服务器 wiki/ 目录里的 → 强制删除（回滚客户端上传）
```

效果：客户端上传的多余文件 30s 内被清除 → 拉取 tombstone → 收敛到服务器状态（不改客户端，服务器权威）。

---

## 6. 相关链接

- [vrtmrz/obsidian-livesync](https://github.com/vrtmrz/obsidian-livesync) — 现用方案（11.9k ⭐）
- [syncthing/syncthing](https://github.com/syncthing/syncthing) — 评估方案（87.5k ⭐）
- [MobiusSync](https://github.com/MobiusSync/MobiusSync) — iOS Syncthing 客户端（$4.99）
- [remotely-save/remotely-save](https://github.com/remotely-save/remotely-save) — 备选（S3/WebDAV，mtime 仲裁，2024-11 后维护放缓）
- [Vinzent03/obsidian-git](https://github.com/Vinzent03/obsidian-git) — 备选（git 权威仲裁最强，iOS 不可用）
