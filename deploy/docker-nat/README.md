# PS Portal 高码率中继：Docker macvlan 双向 NAT 部署

本目录在 Ubuntu 主机上，用 **Docker macvlan 容器** 运行
[ps5-portal-high-bitrate](https://github.com/atameric/ps5-portal-high-bitrate) 的
`raspberry-pi/` **双向 NAT 中继**（`linux_native.py`），并通过 **systemd** 常驻运行。

它的作用：Portal 发起新连接时，中继把启动包里的码率请求从默认约 25 Mbps
改成 65/100/150/200 Mbps 档位，PS5 接受后按新的目标码率编码。
这不是 4K 解锁，也不保证降低延迟；实际视频码率随画面复杂度波动。

## 为什么用这套方案

| 方案 | 结论 |
| --- | --- |
| 宿主机原生 systemd（单向 `portal_auto.py`） | ❌ 要求宿主 `ip_forward=0`，会破坏本机现有 Docker 容器的网络 |
| 官方 `deploy/docker`（单向 macvlan） | ❌ 实测 Portal 全新连接时卡在握手（UDP 9297 COOKIE） |
| 虚拟机 / Proxmox LXC | 不采用（避免嵌套虚拟化） |
| **本目录：双向 NAT + macvlan** | ✅ 全新连接正常，PS5 接受 97 Mbps 目标；不影响宿主和其他容器 |

单向中继只转发 Portal→PS5 方向，PS5 的回包直接发给 Portal，导致新连接握手失败。
双向 NAT 把 Portal 的流量源地址改写成中继 IP，PS5 的回包（包括视频）也经过中继，再转发给 Portal。

## 架构

```
Portal (Wi-Fi, PORTAL_IP)
   │  ARP：PS5 IP → 中继 MAC
   ▼
中继容器 (macvlan, RELAY_IP, RELAY_MAC)
   │  NAT：源地址改为 RELAY_IP；改写启动包的码率请求
   ▼
PS5 (有线, PS5_IP) ── 视频回包 ── 中继 ── Portal
```

- 容器有独立的 MAC、IP 和网络命名空间。`ip_forward=0` 和 nftables 表
  `inet portal_native_nat` 都只在容器内部生效，宿主机和其他容器不受影响。
- 容器能力：`NET_ADMIN`（容器内的 nftables）和 `NET_RAW`（原始套接字收发包）。
- macvlan 的限制：宿主机本身无法访问中继 IP，属于正常现象。

### 宿主机上唯一的改动：关闭网卡接收卸载（GRO）

中继要求网卡关闭 GRO/LRO，否则合并后的大包会破坏转发。macvlan 子接口继承父网卡
（下例为 `eth0`，以实际网卡名为准）的 GRO，并且无法在容器内单独修改，所以必须在宿主机上执行：

```
ethtool -K eth0 gro off rx-gro-hw off
```

systemd 服务在启动前自动关闭 GRO，停止后自动恢复为 on。
代价是宿主机接收大流量时 CPU 占用略增，千兆 virtio 网卡上通常可以忽略。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `portalctl.sh` | 管理脚本（配置、测试、安装服务、监控） |
| `compose.yaml` | macvlan 网络、固定 IP/MAC、能力、sysctl、健康检查 |
| `Dockerfile` | 基于 `python:3.12-slim`，打包 `raspberry-pi/` 中继 |
| `patch_macvlan.py` | 构建时的最小补丁：设置 `PORTAL_ALLOW_MACVLAN=1` 后，接口检查接受 macvlan 网卡 |
| `entrypoint.sh` | 容器入口；转发停止信号，并等待 guardian 修复 ARP 后再退出 |
| `repair_arp.py` | 手动向 Portal 发送 ARP 修复帧（异常断电或强杀后使用） |
| `.env` | 网卡、网段、中继 IP/MAC、PS5/Portal IP、档位（由 `setup`/`configure` 生成，**不要分享**） |
| `data/config/config.json` | PS5/Portal 的 IP 和 MAC（**不要分享**） |
| `data/state/` | baseline 运行记录和人工确认记录（root 所有） |

上游源码不做修改；`patch_macvlan.py` 在构建镜像时对 `linux_native.py` 打补丁（见文末），不修改 git 工作区。

## 首次部署

前提：
- 宿主机通过有线网卡接入 PS5/Portal 所在的二层局域网，不能是 Wi‑Fi。
- 当前用户在 `docker` 组里。
- 中继 IP 必须在 DHCP 池之外，或者在路由器里预留。
- PS5 和 Portal 在路由器里固定 IP。

```bash
git clone https://github.com/haoyouab/ps5-portal-high-bitrate
cd ps5-portal-high-bitrate/deploy/docker-nat
./portalctl.sh setup
```

`setup` 是交互式向导，依次完成：

1. **配置**：确认宿主网卡、网段、网关，**输入 PS5 和 PS Portal 的 IP** 以及中继使用的空闲 IP
   （会校验格式、网段、是否重复，并通过 ping 读取两台设备的 MAC，所以两台设备需开机/唤醒）。
   码率档位默认 **100**，之后可随时切换。
2. **构建镜像** `portal-relay-nat:local`。
3. **关闭宿主网卡 GRO**（sudo）。
4. **预检**。
5. **baseline**：180 秒只转发不改码率。按提示在 Portal 上重新连接 PS5，确认画面和操作正常后回答 `y`，写入确认记录。
6. **安装**（sudo）：systemd 服务 `portal-nat-relay`、命令 `/usr/local/bin/portalctl`（指向本目录脚本）、
   bash 补全，并输出切换档位和 monitor 的用法。

> 安装后请不要移动本目录，`portalctl` 命令和 systemd 服务都指向这里。

也可以手动分步执行：`configure` → `build` → `gro off` → `preflight` → `baseline 180` → `accept` →（可选 `try 300`）→ `install`。

> baseline 确认记录绑定了代码哈希、接口、中继/PS5/Portal 的 IP 和 MAC。
> 其中任何一项变化（包括重新 configure 换了 IP）都要重新执行 baseline 和 accept。
> 只改档位不需要。

## 日常使用

服务安装后会开机自启，Portal 正常连接即可，不需要任何额外操作。
安装后可以在任意目录使用 `portalctl`（支持 Tab 补全）；安装前请在本目录用 `./portalctl.sh`。

```bash
portalctl status            # 服务、网卡 GRO、容器、实时码率一览
portalctl monitor           # 每 2 秒打印码率（in = PS5→Portal 视频）
portalctl logs              # 容器日志
portalctl stop | start | restart
portalctl profile           # 方向键选择码率档位并立即生效
```

`status` / `monitor` 的输出字段：
- `PS5 target`：PS5 回报的目标码率。100 档约为 97.1 Mbps；不经过中继时约 24 Mbps。
- `in`：实际转发的视频码率，2 秒平均值。
- `startups modified`：本次运行中改写的启动包数量。
- `drops` / `errors`：应保持为 0。

**注意：** 中继停止或重启时，经过中继的串流会话会断开（PS5 那边的对端是中继 IP）。
在 Portal 上重新连接即可；中继停止后 Portal 会恢复直连。

### 切换档位

```bash
portalctl profile        # 方向键 ↑/↓（或 1-4）选择，回车确认，q 取消
portalctl profile 65     # 或直接指定：65 / 100 / 150 / 200
```

会同时更新 `.env` 和 `data/config/config.json`；中继正在运行时自动重建容器（无需 sudo，
systemd 服务保持 active），当前串流会断开，在 Portal 上重新连接即可。档位不绑定 baseline，无需重新确认。

建议优先使用 65 或 100。150/200 未经验证，可能出现卡顿。

### 卸载

```bash
portalctl uninstall           # 停止服务、删除 unit、portalctl 命令和补全，恢复 GRO
docker image rm portal-relay-nat:local   # 可选
```

## systemd 服务

`portalctl install` 会生成 `/etc/systemd/system/portal-nat-relay.service`：

- `ExecStartPre`：`ethtool -K <网卡> gro off rx-gro-hw off`
- `ExecStart`：`docker compose up -d --wait`，等容器健康检查通过才算启动成功
- `ExecStop`：`docker compose down`，最多等 45 秒，让中继修复 Portal 的 ARP
- `ExecStopPost`：恢复 GRO

容器的重启策略是 `restart: unless-stopped`，中继崩溃时由 Docker 自动重启。
如果主机意外断电，Docker 可能在 systemd 关闭 GRO 之前先拉起残留容器。
这时预检会失败，容器会反复重启，直到 GRO 被关闭为止，期间不会发送任何 ARP。

## 实测结果（Ubuntu 24.04 KVM 虚拟机 + virtio 千兆网卡，PS5 固件 14.23，100 档）

| 项目 | 默认（baseline） | 100 档 |
| --- | --- | --- |
| PS5 目标码率 | 24.3 Mbps | 97.1 Mbps |
| 实际码率（中继 2 秒采样） | 约 4–7 Mbps | 中位 22，P90 36，峰值 52 Mbps |
| Portal 显示 | 约 10 Mbps | 30–60 Mbps 波动 |
| 丢包 / 错误 | 0 | 0 |
| 主观体验 | — | 画质明显更好，流畅 |

## 故障排查

**Portal 提示“连接时间过长，请稍后再试”，直连也失败**
如果局域网的 DNS/网关是代理（例如 Clash fake-ip 模式），PSN 相关流量走了慢速代理时，
Portal 在连接局域网 PS5 之前就会超时，这与中继无关。
解决办法：在代理中为 Portal/PS5 或 PSN 相关域名、端口设置 DIRECT 规则。

**`preflight` / 服务启动报 `Unsupported receive offloads enabled`**
GRO 没有关闭。执行 `portalctl gro off`，或检查服务的 `ExecStartPre` 是否执行成功。

**新连接偶尔失败一次**
实测中出现过第一次连接失败、第二次成功的情况。重试即可。
如果持续失败，用 `portalctl monitor` 查看 `in`/`out` 是否有流量。

**中继被强杀或断电后，Portal 连不上 PS5**
Portal 的 ARP 可能还指向中继的 MAC。依次尝试：重启 Portal；
`portalctl stop && portalctl repair-arp`。

**`forwarded` 为 0，但 Portal 已被重定向**
检查 PS5、Portal、中继是否在同一网段，并且没有开启 AP 客户端隔离。

**更换宿主网卡名或中继 IP**
重新运行 `portalctl setup`（会重新配置、baseline 并重装服务）。

## 隐私

`.env`、`data/` 包含设备的 IP/MAC 和运行记录，已加入 `.gitignore`，请不要公开分享。

## 附：本地补丁说明（patch_macvlan.py）

构建镜像时对上游 `linux_native.py` 打两处补丁：

1. **允许 macvlan 接口**（仅当 `PORTAL_ALLOW_MACVLAN=1`）：跳过上游对虚拟网卡的拒绝。
2. **TX 发送 EAGAIN 重试**：上游 TX 套接字为非阻塞，macvlan 发送队列瞬时写满时抛出 `BlockingIOError` 导致中继崩溃、Portal 回落直连。补丁改为 `select` 等待可写并重试（最多 0.5 秒），并把 `SO_SNDBUF` 调到 4 MB。

补丁改变了 `code_sha256`，因此升级/修改补丁后必须重新执行 `baseline` + `accept`，否则 active 模式会被门禁拒绝。
