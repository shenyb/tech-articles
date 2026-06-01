# JDBC 连接超时参数：connectTimeout 和 socketTimeout

## 问题

一次 MySQL 主从切换，DBA 预期只阻塞 10~20 秒，结果服务挂了 15 分钟才恢复。

原因是 RDS 域名走了腾讯网关（TGW），主从切换时旧连接被 TGW 侧保持，但应用侧没有配置 JDBC 连接超时参数，**获取连接的线程一直阻塞等待，既不失败也不重连**，直到 TGW 默认 15 分钟超时断开，应用才收到异常重新获取连接。

## 两个参数

### connectTimeout（连接超时）
- 控制：JDBC 驱动与 MySQL 服务器**建立 TCP 连接**的超时时间
- 单位：毫秒，比如 `connectTimeout=3000` 表示 3 秒连不上就抛异常
- 默认值：0（无限等待）
- 本质：防止 TCP 握手阶段卡死

### socketTimeout（读取超时）
- 控制：通过 TCP 连接**发送 SQL 后等待响应**的超时时间
- 单位：毫秒，比如 `socketTimeout=30000` 表示 30 秒没收到响应就断开
- 默认值：0（无限等待）
- 本质：防止 SQL 执行阶段卡死

## 配置方式

```properties
# JDBC URL 追加参数
jdbc:mysql://host:port/db?connectTimeout=3000&socketTimeout=30000
```

```yaml
# 或者 Spring Boot 数据源配置
spring:
  datasource:
    hikari:
      connection-timeout: 3000
      socket-timeout: 30000
```

## 教训

1. **连接池参数 ≠ 连接超时** —— 连接池的 `maxWait`/`connectionTimeout` 控制的是从池子里拿连接等待的时间，而 `connectTimeout`/`socketTimeout` 控制的是 JDBC TCP 层面的超时
2. JDBC 默认超时是 **0（无限等待）**，意味着任何一个网络层面的卡住（主从切换、交换机故障、网关问题）都会导致线程永久阻塞
3. TGW/LVS 这类 4 层网关有自己的连接超时（通常 15 分钟），但不应该指望它来兜底
4. 主从切换这类线上操作前，应通知关联业务方，并确认应用层有超时保护

## 关联

- MySQL 官方文档: https://dev.mysql.com/doc/connector-j/8.0/en/connector-j-connp-props-connection.html
- TGW 默认超时: 15 分钟
- 故障复盘: 20230425-数据库主从切换导致服务挂掉15分钟 (docs.58corp.com)
