# Monitor Script For FnOS on hikvision R1

一个用于在海康威视R1的前面板显示器（376x960分辨率）上显示飞牛OS系统信息的 Bash 脚本。它提供了 CPU、内存、温度、网络状态和硬件信息的概览。

## 功能特性

*   **垂直布局**: 专为窄而高的显示器优化。
*   **系统概览**:
    *   CPU 使用率（百分比和进度条）
    *   内存使用率（百分比和进度条）
    *   平均 CPU 温度（带颜色阈值）
    *   系统运行时间
*   **硬件信息**:
    *   CPU 型号、核心数、线程数
    *   总内存大小 (GiB)
    *   GPU 型号 (检测到的第一个)
*   **详细网络信息**:
    *   列出活动的物理网络接口。
    *   显示每个接口的 IP 获取方式 (DHCP/Static)。
    *   显示 IPv4 地址、子网掩码、网关和 DNS 服务器。
    *   显示 IPv6 地址 (全局范围)。
*   **网络速度监控**:
    *   显示每个物理接口的实时下载 (↓) 和上传 (↑) 速度 (KB/s, MB/s, GB/s)。
    *   为下载和上传速度提供历史趋势的 Sparkline 图表。
    *   使用后台进程计算速度，避免阻塞主显示。
*   **FnOS Logo**: 在顶部显示 ASCII 艺术 Logo。
*   **颜色编码**: 使用颜色区分不同的信息和状态。
*   **依赖检查**: 自动检测所需命令是否存在，并在缺少时优雅地处理。
*   **资源清理**: 在退出时（Ctrl+C）自动清理后台进程和临时文件。

## 依赖项

为了完整显示所有信息，脚本依赖于以下命令行工具：

*   **核心**: `bash`, `awk`, `grep`, `sed`, `tput`, `date`, `sleep`, `cat`, `mktemp`, `kill`, `printf`, `ip`
*   **CPU/内存**: `mpstat` (推荐) 或 `top`, `free`
*   **温度**: `sensors` (来自 `lm-sensors` 包)
*   **硬件信息**: `lscpu`, `lspci` (来自 `pciutils` 包)
*   **网络速度 (可选优化)**: `sar` (来自 `sysstat` 包) - 如果可用，用于更精确的速度计算；否则回退到 `/sys` 接口。
*   **网络详情 (可选增强)**: `resolvectl` (来自 `systemd`) 或 `nmcli` (来自 `NetworkManager`) - 用于更可靠地检测 DNS 和 IP 获取方法；否则回退到解析 `/etc/resolv.conf`。

请确保这些工具已安装在您的系统上。您可以使用系统的包管理器来安装它们。

例如，在飞牛OS系统上：
```bash
sudo apt update
sudo apt install coreutils procps util-linux iproute2 lm-sensors pciutils sysstat network-manager systemd # (systemd 通常已存在)
```

## 安装

1.  将 `monitor.sh` 文件保存到nas。
2.  授予脚本执行权限：
    ```bash
    chmod +x monitor.sh
    ```

## 用法

直接运行脚本：

```bash
./monitor.sh
```

脚本将开始显示系统信息，并按 `INTERVAL` 变量设定的时间（默认为 5 秒）刷新。

按 `Ctrl+C` 停止脚本。脚本会尝试清理后台进程和临时文件。

## 配置

您可以通过编辑脚本顶部的变量来自定义脚本的行为：

*   `INTERVAL`: 刷新屏幕的间隔时间（秒）。默认值为 `5`。
*   `HISTORY_POINTS`: 网络速度 Sparkline 图表中显示的历史数据点数量。默认值为 `25`。
*   `FNOS_LOGO`: 可以替换为您自己的 ASCII 艺术 Logo。

## 示例输出 (模拟)

```
 ███████╗███╗   ██╗ ██████╗ ███████╗
 ██╔════╝████╗  ██║██╔═══██╗██╔════╝
 █████╗  ██╔██╗ ██║██║   ██║███████╗
 ██╔══╝  ██║╚██╗██║██║   ██║╚════██║
 ██║     ██║ ╚████║╚██████╔╝███████║
 ╚═╝     ╚═╝  ╚═══╝ ╚═════╝ ╚══════╝
 script by Glory & Gemini 2.5 Pro

CPU       : Intel Core i7-8700K...
          : 6C 12T
Memory    : 31.3G
GPU       : NVIDIA GeForce GTX 1080 Ti
----------------------------------------
CPU       : [████████████░░░░░░░░]  60%
Memory    : [████████████████░░░░]  75%
Avg Temp  : 65.0°C
Uptime    : 3d 14h 25m
----------------------------------------
Network Interfaces:
eth0
IP Method:  DHCP
IPv4:
    Address:        192.168.1.100
    Subnet Mask:    255.255.255.0
    Gateway:        192.168.1.1
    DNS:            1.1.1.1 8.8.8.8
IPv6:
  Address:
      240e:xxxx:xxxx:xxxx::1/64
      fe80::xxxx:xxxx:xxxx:xxxx/64

wlan0
IP Method:  DHCP
IPv4:
    Address:        192.168.2.50
    Subnet Mask:    255.255.255.0
    Gateway:        192.168.2.1
    DNS:            192.168.2.1
IPv6:
  Address:
      N/A

----------------------------------------
Network Speed:
  [eth0      ]
 ↓ : 1234.5 KB/s [  ▂▃▄▅▆▇██▇▆▅▄▃▂      ]
 ↑ :  123.4 KB/s [   ▂▂▃▃▄▄▅▅▆▆▇▇██     ]
  [wlan0     ]
 ↓ :    0.0 KB/s [                      ]
 ↑ :    0.0 KB/s [                      ]
----------------------------------------
```

## 贡献者

*   Glory
*   Gemini 2.5 Pro

## 许可证

[MIT License](LICENSE)
