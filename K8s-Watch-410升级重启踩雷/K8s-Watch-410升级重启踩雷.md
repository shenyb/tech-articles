# 滚动升级后 Watch 410 循环告警：重启一小时无效，删 Redis key 才恢复

> **TL;DR** 2026-08-20 傍晚，部署平台滚动升级到 `4.0.0.731` 后，正式环境 env 117（高新-chc）的 Pod 事件监听开始疯狂报 **HTTP 410 `resourceVersion too old`**。微信告警每 3 分钟一条，我重启、回滚、停服折腾了一个多小时，**都没好**。最后删掉 Redis 里一个共享 bookmark key，再重启，watch 才恢复正常。根因不是 K8s 挂了，而是 **启动续传用的 Redis revision 已经落后于 etcd 压缩线**——而旧代码的断连重连逻辑，在业务高峰下也救不回来。

---

## 📌 本文要点

- **K8s Watch 续传靠 bookmark**：`resourceVersion` 是 etcd 全局递增版本号，过期就 410，只能全量 List 再 Watch
- **启动读 Redis、断连传 null**：两条建连路径行为不一致，是这次「重启无效」的关键
- **Redis 与 DB 双通道分叉**：部分早退路径只写 DB 不写 Redis，bookmark 长期偏低
- **高峰下 null 全量扛不住**：4 分钟 10 万条 handler 日志，积压 → 断连 → 再 410，形成恶性循环
- **人工 DEL key = 代码化自愈**：修复侧写入单调递增 + 早退补写 + 410 自动清 bookmark

---

## 🏗️ 背景：部署平台怎么盯 Pod 事件

我们的容器部署平台（yundeployment）靠 **K8s Watch** 实时感知 Pod 变化：创建、就绪、删除，驱动蓝绿发布、PodInfo 落库等逻辑。

Watch 不是每次从零开始。K8s 允许你带上上次收到的 **`resourceVersion`** 续传——相当于书签，告诉 apiserver「我从这里接着听」。

这个书签在我们系统里叫 **bookmark**，存在 Redis：

```text
Key: DeploymentPodResourceVersion-{envId}
Value: 最近一次成功处理事件的 resourceVersion
```

三台部署节点 **共用同一个 Redis key**。谁最后写入，谁就决定了下次重启从哪续传。

听起来很合理。直到升级那天，这个 bookmark **比 etcd 还旧**。

---

## ☎️ 傍晚的告警：重启没用，回滚也没用

18:17 起，四台部署节点陆续滚动上线 `4.0.0.731`。18:21，重灾区节点 10.72.6.73 进程起来不到 2 秒，日志里就出现：

```log
too old resource version: 4888107242 (4888123393)
```

翻译：`4888107242` 是我们从 Redis 读到的 bookmark；`4888123393` 是 etcd 当前最小可用 revision。**bookmark 落后约 1.6 万**，apiserver 直接 410，Watch 建连失败。

紧接着微信告警：

**「正式环境(高新-chc) 事件监听由于异常关闭，请尽快处理！」**

接下来一个多小时的操作，和云平台部署记录对得上：

| 时间 | 操作 |
|------|------|
| 18:54 ~ 18:58 | 人工重启 73 / 74 |
| 19:02 | 回滚 73 到 730 |
| 19:07 | 再次上线 731 |
| 19:38 | 停止 73 / 74 |

**每一次重启，410 都回来。** 体感就是：系统在自愈和告警之间空转，人越折腾越糟。

最终恢复手段很「土」，但有效：

```bash
DEL DeploymentPodResourceVersion-117
# 然后重启 yundeployment 进程
```

key 删了，启动时读不到 bookmark → 等价于 `null` 全量 List + Watch → 正常。

---

## 🔍 第一眼：410 出现在启动后 2 秒

这是整件事最重要的线索。

如果是「处理事件太慢导致 bookmark 落后」，410 应该出现在跑了一段时间之后。但日志显示：

| 时间 | 事件 |
|------|------|
| 18:21:18 | 从 DB 读 env 117 resourceVersion = **4888138566** |
| 18:21:19 | 从 Redis 读 bookmark，启动 PodInfoWatcher = **4888107242** |
| 18:21:19 | **立刻 410** |

进程还没处理任何 Pod 事件，bookmark **本身就已经过期**。

同一时刻，DB 里的 version 反而 **领先 etcd 约 3 万**，可以续传。说明不是「三台都停了没人写」，而是 **Redis 这条通道长期偏低**。

---

## 💡 先搞清楚：旧代码有两条建连路径

8/20 线上旧代码里，**启动**和**断连重连**走的是完全不同的逻辑：

| 场景 | bookmark 来源 | 行为 |
|------|--------------|------|
| **进程启动** | **读 Redis** | 带 bookmark 续传 |
| **Watch 断连 onClose** | **固定传 `null`** | 全量同步，不读 Redis |

```java
// 启动 — 读 Redis
String resourceVersion = dao.getPodEventResourceVersion(envType);
eventWrapper.podWatch(new PodInfoWatcher(envType), resourceVersion);

// 旧 onClose — 始终 null
eventWrapper.podWatch(new PodInfoWatcher(envType), null);
```

**事故触发点在启动**：重启 = 必读 Redis = 踩过期 bookmark = 立刻 410。

这也解释了为什么「重启无效」——只要 Redis key 里还是过期值，每次重启都会重演。

---

## 🔗 那为什么 onClose 传 null 也没救回来？

直觉上，`null` 是全量同步，应该能绕过过期 bookmark。8/20 日志却显示 env 117 从 18:21 到 19:38 **持续 410，共 14 次**。

### ① 410 的 revision 在变，不是反复读同一个 Redis 值

| 时间 | 410 报文 revision | 说明 |
|------|------------------|------|
| 18:21:19 | 4888107242 | 启动读 Redis |
| 18:24:17 | 4863258726 | 与 Redis 不同，更旧 → null 全量/List 后拿到的位点仍过期 |

若 null 全量能稳定恢复，不应每 ~3 分钟换一个新的旧 revision 再 410。

### ② 业务高峰下，全量扛不住

18:00 前后业务集群集中上线，env 117 的 Pod 事件量从约 **2.5 万/h 升到 7 万/h**。18:21~18:25 仅 4 分钟，`PodInfoHandler` 日志 **10 万+ 条**。

全量 List 泄洪 + 增量叠加，处理慢于到达速度 → watch 积压 → 断连 → onClose 再 null 全量 → **恶性循环**。

### ③ 告警与恢复脱钩

旧逻辑：**5 分钟内再次断连就发微信**，不管 null 重连是否已拉过全量。体感就是「没恢复，一直在告警」。

### ④ 人工反复重启放大问题

18:54 起多次重启，每次都再走 **启动读 Redis** → 再次踩过期 bookmark。

旧代码死循环：

```text
启动读 Redis(过期) → 410
  → onClose(null) 全量 → 短暂收事件 → 高峰积压 → 再 410
  → 5min 内断连告警
  → 人工重启 → 再次启动读 Redis → …
```

---

## 🧨 为什么 Redis bookmark 会「过期」

bookmark 不是 etcd 全集群进度，只是「我们处理过的事件」里的最大 revision。以下因素会让 Redis 长期偏低：

| 因素 | 说明 |
|------|------|
| **Redis / DB 双通道** | PodInfoWatcher 写 Redis；PodWatcher 写 DB。旧代码部分早退路径 **只写 DB、不写 Redis** |
| **bookmark 非全集群** | etcd 压缩线由全集群所有资源变更推进；Redis 只记录我们订阅到的事件 |
| **多节点无脑 set** | 三台并发写同一 key，可能出现 **写退**（后写入更小 revision） |
| **启动无过期保护** | 旧代码启动必读 Redis，无「过期则改 null」 |
| **onClose 不清 Redis** | 断连全量救不回来时，过期 key 一直留着，下次重启继续踩 |

73 重启时刻 env 117 对比：

| 存储 | resourceVersion | 相对 etcd 最小可用 |
|------|-----------------|-------------------|
| Redis（启动用） | 4888107242 | 落后约 1.6 万 → 410 |
| DB（PodWatcher 用） | 4888138566 | 领先约 3 万 → 可续传 |

---

## 🎯 为什么偏偏这次升级才爆

平时滚动升级也重启，为什么 8/20 才炸？**多重因素叠加的偶发踩线**：

1. 四台节点依次重启，每台启动都要读 Redis 续传
2. 18:00 前后业务集中上线，etcd revision 与 compaction 加速
3. **时间窗口差**：159 于 18:18 重启时 bookmark 还在窗口内；73 于 18:21 重启时已不可用
4. 旧代码启动无保护 + 人工多次重启 → 反复触发

排除项也查过：Job/EventWatcher 在 18:00 段 **0 次** 410；410 出现在启动后 2 秒，不是「新节点来不及写 Redis」。

---

## 🛠️ 怎么修的：五类改动

已在部署平台服务中合入修复，归纳成五类：

| # | 类别 | 解决的问题 | 主要改动 |
|---|------|-----------|---------|
| 1 | **重连续传** | 旧 onClose 固定 null，日常断连也全量 | onClose 改读 Redis/DB；410 时 fallback null |
| 2 | **410 自愈** | 需人工 DEL bookmark 才能恢复 | 410 时自动清 Redis/DB bookmark + 内存 map |
| 3 | **写入单调性** | 多节点并发写可能写退 | 仅在新 revision 更大时写入；热路径 try/catch |
| 4 | **早退补写** | 早退只写 DB 不写 Redis，双通道分叉 | PodInfoWatcher 全早退补 Redis；PodWatcher 早退补 DB |
| 5 | **空指针防护** | metadata/labels 空导致 NPE，中断写入 | 入口判空；抽取 syncPodResourceVersion |

修复后 410 重连路径：

```text
onClose → 判定 410
       → clearPodEventResourceVersion(Redis) / clearEventResourceVersion(DB)
       → resourceVersion = null → 全量同步
       → 新事件单调递增写回 bookmark
```

这就是把 8/20 **人工 `DEL DeploymentPodResourceVersion-117`** 代码化了。

---

## 💭 事后复盘：我学到的东西

### 1. 「重启」不等于「从头开始」

很多运维直觉是：挂了？重启。  
但 Watch 续传系统里，**重启读的是持久化 bookmark，不是 clean slate**。bookmark 过期时，重启 = 带着过期的书签撞墙。

设计续传型监听时，要问：**持久化位点过期时，启动路径会不会自动降级为全量？**

### 2. 两条路径行为不一致，是排查陷阱

启动读 Redis、断连传 null——看起来 onClose 更「保守」，实际上 **真正致命的是启动路径**。排查时如果只盯 onClose，会得出「null 全量应该能恢复」的错误结论。

**同一资源的建连/重连/启动，bookmark 来源和行为应文档化、应一致或有明确降级策略。**

### 3. 双写通道必须对账

Redis 写 PodInfo、DB 写 PodWatcher，早退漏写其中一条，就会出现「DB 很新、Redis 很旧」。这次 73 重启时刻就是铁证。

**要么统一存储，要么保证每条处理路径双写，要么定期对账。**

### 4. 高峰下的「全量」不是免费午餐

null 全量在低峰可能是自愈手段；在 revision 暴涨 + 事件洪峰时，List 本身就会制造新一轮积压。  
**全量降级要配限流、批处理、或错峰，不能假设「List 一次就好」。**

---

## 🔚 写在最后

这次事故最憋屈的地方在于：**恢复手段其实早就知道**——删 Redis key，全量重建。但旧代码没有任何一步自动走到那里；人反复重启，反而一次次把过期 bookmark 读回来。

一行 DEL、一套 410 清 key 逻辑、一处早退补写——缺任何一环，就会在升级窗口 + 业务高峰的叠加下，把「偶发踩线」变成「一个多小时出不去」。

---

## ✅ 复盘 Checklist：做 K8s Watch 续传前过一遍

- [ ] **启动、断连、定时重建三条路径，bookmark 从哪来？过期时怎么办？**
- [ ] **410 时是否自动清持久化位点并 fallback 全量？** 别指望人工 DEL
- [ ] **多节点写同一 bookmark，是否单调递增？** 防写退
- [ ] **每条事件处理路径（含早退）都更新 bookmark 吗？** 双通道是否分叉
- [ ] **全量降级在高峰下扛得住吗？** List 泄洪 + 增量会不会 worse
- [ ] **升级窗口与业务发布窗口错开了吗？** revision 暴涨时重启风险更高

都是小事。但 Watch 410 这种错，往往就是这些小事的乘积。

---

📝 博客原文：[干货·工程化复盘](https://ganhuo.dev/blog/k8s-watch-410-bookmark-outage/)
