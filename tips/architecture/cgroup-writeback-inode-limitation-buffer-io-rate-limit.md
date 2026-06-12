# cgroup writeback 的 inode 级限速局限：限速 grep 连带影响了服务进程

## 先搞懂 cgroup 是什么

cgroup（Control Group）是 Linux 内核的**资源隔离机制**。你可以把一组进程划到一个组里，然后对这个组做资源限制：

```
进程 A ─┐
进程 B ─┤
进程 C ─┤
         ├── cgroup "online"    → CPU 限制 4 核，内存 2GB
         │
进程 D ──┤
         └── cgroup "batch"     → CPU 限制 1 核，内存 512MB
```

常见用法：
- CPU 隔离：cgroup A 最多用 4 核，cgroup B 最多用 1 核 ✅ 隔离得很好
- 内存隔离：cgroup A 最多用 2G，cgroup B 最多用 512M ✅ 隔离得很好
- **磁盘 IO 隔离**：❌ 这个最麻烦，下面讲

## Buffer IO vs Direct IO

Linux 读写文件有两种模式：

**Direct IO**：直接读写磁盘，不经过内核缓存。
- 比如数据库自己管理缓存时
- cgroup 对 Direct IO 的限速是准的（per-process）

**Buffer IO（缓冲 IO）**：先读写到内核的 page cache（页缓存），内核再异步刷到磁盘。
- 大部分普通程序（grep、cat、Java 写日志）都是 Buffer IO
- 写文件：进程写到 page cache 就返回了，**内核再慢慢把脏页写到磁盘**
- 读文件：先看 page cache 有没有，没有再从磁盘读

类比：
> Direct IO = 你自己去仓库搬货，每一步你都知道搬了多少
> Buffer IO = 你把货堆在门口，仓库管理员慢慢往里面搬——你只知道"放门口了"，但管理员搬了多少你不知道

## 场景

云平台发现开发经常在生产容器里执行 `grep` 查日志，28GB 的日志文件 grep 能跑到 1GB/s 的读速率，把整台物理机的磁盘 IO 打满，影响同机其他容器。

于是上线了一个"命令限速"功能：
1. 监测物理机磁盘 IO 使用率 > 50%
2. 找到所有容器中的 grep/cat 进程
3. 把 grep 进程加入独立 cgroup，限速 100MB/s

理论上：限速只针对那个独立的 cgroup，服务进程在另一个 cgroup，互不影响。

实际上：**服务进程的写入也变慢了。**

## 根因：cgroup writeback 的 inode 粒度局限

Linux 内核的 **cgroup writeback** 机制，用一句话说就是：

> 当多个 cgroup 中的进程操作同一个文件时，内核无法分开追踪各自的脏页。

因为 cgroup writeback 的追踪粒度是 **inode（文件元数据）**，不是进程：

```
文件 tiryns.log（同一个 inode）
    ↑
    ├── grep 进程 (cgroup A)  → 读这个文件
    └── 服务进程 (cgroup B)  → 写这个文件

正常情况下应该：
  限速 cgroup A 的 IO     → 只影响 grep
  不影响 cgroup B 的 IO   → 服务进程正常

但实际上：
  限速 cgroup A 的读 IO
  → 因为同文件 inode 的 writeback 路径是共享的
  → 内核把这个 inode 关联的所有脏页追踪都压制了
  → 服务进程的写入也变慢了
```

类比：
> 想象一个仓库（文件）有两个通道（cgroup）：
> - 通道 A 在搬货（grep 读文件），管理员说"通道 A 限速"
> - 通道 B 也在同一仓库搬货（服务写文件）
> - 但因为两个通道共用一个仓库大门（inode 级别的 writeback 控制）
> - 限速通道 A 的时候，大门变窄了，通道 B 也被卡住了

## 为什么 CPU/内存隔离没这个问题

| 资源 | 隔离粒度 | 是否受其他 cgroup 影响 |
|------|---------|---------------------|
| CPU | 进程/线程级 | ❌ 各 cgroup 独立调度 |
| 内存 | 进程级 | ❌ 各 cgroup 独立分配 |
| **磁盘 IO（Buffer IO）** | **inode 级** | **✅ 会！同文件会互相影响** |
| 磁盘 IO（Direct IO） | 进程级 | ❌ 各 cgroup 独立限速 |

CPU 和内存的隔离是**进程级**的，每个进程有自己的 CPU 时间片和内存页。但 Buffer IO 的 writeback 是**以文件为单位**的——内核在后台把脏页刷到磁盘时，它不管这些脏页是哪个 cgroup 产生的，都走同一个 writeback 路径。

## 启示

1. **"理论不影响"不等于"实际不影响"** — 这个功能上线前做过测试和理论分析，都认为只影响限速的 cgroup。但没覆盖"不同 cgroup 操作同一个文件"的场景。真正的 bug 往往藏在"你以为不会发生"的组合里。

2. **磁盘 IO 隔离是容器化最后一块难啃的骨头** — CPU、内存、网络的容器隔离已经比较成熟了，但磁盘 IO 的隔离（尤其是 Buffer IO）至今仍然是 Linux 内核的一个痛点。新版内核（5.x+）在 cgroup writeback 上有所改进，但不能完全解决"同文件多 cgroup 互不干扰"的问题。

3. **大日志文件查询本身就是一种反模式** — 28GB 的日志文件，用 grep 搜索。如果日志按天/按小时拆分、或者有日志中心可以查，就不需要在生产容器里跑 grep。这也是改进措施里的"日志拆分""导出离线日志"的出发点。
