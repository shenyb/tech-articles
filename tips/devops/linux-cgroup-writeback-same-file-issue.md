# Linux cgroup writeback 限速的 "同文件干扰" 缺陷

## 问题

云平台搞了个"命令限速"功能：宿主机实时监测磁盘 IO 利用率（IOutil），超过阈值（50%）时，查找容器中正在执行 grep/cat 等 IO 密集型命令的进程，将其加入独立 cgroup 组并限制磁盘 IO 速率（读写各 100MB/s）。

灰度期间，一位开发在容器中对 28GB 日志文件执行 `grep`，grep 进程被限速。但**服务主进程对同一个日志文件的写入也受到了影响**，耗时飙升，导致验真接口超时，触发了错误弹窗。

## 根因

Linux 内核的 **cgroup writeback（buffer IO 限速）有一个设计缺陷**：当**多个 cgroup 下的进程操作同一个文件**时，内核无法分别限速互不干扰。

具体来说：
- 服务进程（cgroup A）往 `tiryns.log` 写入
- grep 进程（cgroup B）读取同一个 `tiryns.log`
- 当 cgroup B 的 grep 被限速时，cgroup A 的服务写入也被连带影响

这是因为内核在 buffer IO 层的 cgroup writeback 是以 **inode（文件）** 为粒度关联的，不是以进程/cgroup 为粒度。多个 cgroup 共享同一个文件页缓存，限速逻辑会相互干扰。

## 教训

1. **cgroup 限速不是完美的隔离方案**——同文件跨 cgroup 操作时存在盲区
2. 测试要覆盖边界场景：同文件读写不同 cgroup 的交叉影响
3. 服务本身要对依赖接口的超时做优雅降级（异常时默认通过比默认拒绝更安全）
4. 日志文件宜拆分（按天/按大小滚动），避免单文件过大诱发这类问题
5. 变更灰度前应周知相关业务线，建立变更沟通渠道

## ref

- Linux kernel cgroup writeback 文档: `Documentation/admin-guide/cgroup-v2.rst`
- 故障复盘文档: 20250416 hrg 验真提醒弹窗误触发故障（docs.58corp.com）
