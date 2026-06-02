# K8s controller-manager 驱逐策略优先级高于 Pod tolerationSeconds

## 场景

Node 失联（交换机故障），预期 Pod 默认容忍 3 天（通过 apiserver 参数 `--default-not-ready-toleration-seconds=259200`），但实际上 Node 失联后约 70 秒 Pod 就被驱逐了。

## 根源

K8s 中有两套独立的时间配置：

| 配置 | 位置 | 作用 |
|------|------|------|
| `--default-not-ready-toleration-seconds` | kube-apiserver (v1.24-) / kube-scheduler (v1.25+) | 设置 Pod 的 `tolerationSeconds` 默认值，标记在 **Pod 自身** |
| `--pod-eviction-timeout` | kube-controller-manager | NodeController 的 **驱逐超时**，从 Node 状态变为 NotReady 时开始计时 |

当 Node 失联（网络不通）时：
1. kube-controller-manager 的 NodeController 检测到 Node 状态异常
2. 等待 `--pod-eviction-timeout`（默认 70s）后，直接驱逐该 Node 上的所有 Pod
3. Pod 即使设置了 `tolerationSeconds=259200`，也**不会跳过驱逐**，因为 NodeController 按 Node 维度驱逐，不受单个 Pod toleration 控制

**关键区别**：tolerations 控制的是「Pod 是否允许调度到不健康的 Node」，但 NodeController 的驱逐是「Node 不可达太久，批量清理该 Node 上的 Pod」。前者是 Pod 级别的容忍，后者是集群级别的驱逐策略，后者优先级更高。

## 高可用测试盲区

团队做高可用测试时只测了 kubelet 重启场景，未覆盖 Node 断网/失联场景。两种故障模式下：
- **kubelet 重启**：Pod 走重建流程，tolerationsSeconds 生效
- **Node 失联**：走 NodeController 驱逐流程，`--pod-eviction-timeout` 生效

修复方案：为 DB 集群配置定制化的 `--pod-eviction-timeout=86400s`（1 天），减少误驱逐风险。

## 教训

1. **Node 失联 ≠ kubelet 重启**，两种故障模式走不同的 K8s 控制环路
2. 集群级参数（controller-manager）优先级 > Pod 级配置（tolerations）
3. 高可用测试要覆盖：Pod 崩溃、Node 重启、Node 失联（断电/网络）至少三种场景
4. Node 驱逐后旧 IP 可能被锁定无法释放，需人工清理
