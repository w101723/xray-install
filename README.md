# Xray Production Installer

一个面向 Linux `systemd` 环境的精简 Xray-core 安装/升级脚本。

设计目标是只负责 **Xray-core、systemd 服务和多配置文件运行方式**，默认不安装 GeoData，也不创建独立日志目录。适合自行维护 Xray JSON 配置、Nginx、TLS、防火墙等组件的生产环境。

## 功能

- 安装 Xray-core 最新稳定版
- 安装、升级或降级到指定版本
- 默认仅安装 Xray-core
- 支持自定义多配置文件目录
- 使用 `xray run -confdir` 加载多个 JSON 配置
- 自动生成并启用 `xray.service`
- 默认创建独立 `xray` 系统用户运行服务
- 下载官方 Release 并校验 `.dgst` SHA256
- 重启服务前自动执行配置检测
- 升级失败自动恢复旧二进制和旧 systemd 服务
- 支持 HTTP / SOCKS5 等 curl 下载代理
- 日志默认使用 systemd journal

## 默认安装结构

默认安装后主要包含：

```text
/usr/local/bin/xray
/usr/local/etc/xray/
/etc/systemd/system/xray.service
/etc/xray-install.conf
```

默认 **不会创建或安装**：

```text
/usr/local/share/xray/
/usr/local/share/xray/geoip.dat
/usr/local/share/xray/geosite.dat

/var/log/xray/
/var/log/xray/access.log
/var/log/xray/error.log
```

日志直接由 systemd/journald 管理。

## 系统要求

- Linux
- systemd
- root 权限
- 支持的 CPU 架构：
  - x86 / x86_64
  - ARM v5 / v6 / v7 / ARM64
  - MIPS / MIPS64
  - PPC64 / PPC64LE
  - RISC-V 64
  - s390x
- 支持自动安装依赖的软件包管理器：
  - `apt-get`
  - `dnf`
  - `yum`
  - `zypper`
  - `pacman`

脚本依赖 `curl`、`unzip`、`sha256sum` 等基础工具；缺失时会尝试自动安装。

## 安装

### 一键安装（推荐）

通过 GitHub 直接下载执行，无需先克隆仓库：

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/w101723/xray-install/main/xray-install-production.sh) install
```

国内网络或需要代理时：

```bash
sudo bash <(curl -Ls --proxy socks5h://127.0.0.1:1080 \
  https://raw.githubusercontent.com/w101723/xray-install/main/xray-install-production.sh) \
  install
```

> 该方式脚本内部下载 Xray Release 仍走 GitHub；如需代理也可在执行后通过 `--proxy` 重新运行 `upgrade`。

其他操作同样支持一键方式：

```bash
# 升级到最新版
sudo bash <(curl -Ls https://raw.githubusercontent.com/w101723/xray-install/main/xray-install-production.sh) upgrade

# 仅重新生成 systemd 服务
sudo bash <(curl -Ls https://raw.githubusercontent.com/w101723/xray-install/main/xray-install-production.sh) service

# 查看状态
sudo bash <(curl -Ls https://raw.githubusercontent.com/w101723/xray-install/main/xray-install-production.sh) status
```

### 本地执行

先克隆仓库并添加执行权限：

```bash
git clone https://github.com/w101723/xray-install.git
cd xray-install
chmod +x xray-install-production.sh
```

安装最新稳定版：

```bash
sudo ./xray-install-production.sh install
```

默认配置目录：

```text
/usr/local/etc/xray
```

如果目录中不存在任何 `.json` 文件，脚本会创建：

```text
/usr/local/etc/xray/00-base.json
```

内容为：

```json
{}
```

已有 JSON 配置不会被覆盖。

## 多配置文件

Xray 使用：

```bash
/usr/local/bin/xray run -confdir /usr/local/etc/xray
```

加载配置目录中的多个 JSON 文件。

推荐按功能拆分，例如：

```text
/usr/local/etc/xray/
├── 00-log.json
├── 10-inbounds.json
├── 20-outbounds.json
├── 30-routing.json
└── 40-dns.json
```

自定义配置目录：

```bash
sudo ./xray-install-production.sh install \
  --config-dir /etc/xray/conf.d
```

之后脚本会将配置目录记录到：

```text
/etc/xray-install.conf
```

后续执行普通 `upgrade` 时会继续使用该目录。

## 升级

升级到最新稳定版：

```bash
sudo ./xray-install-production.sh upgrade
```

如果当前已经是最新版本，默认不会重新下载二进制，但仍会刷新脚本管理的 systemd 服务。

强制重新安装当前目标版本：

```bash
sudo ./xray-install-production.sh upgrade --force
```

## 指定版本

安装或升级到指定版本：

```bash
sudo ./xray-install-production.sh upgrade \
  --version v26.3.27
```

也可以省略 `v`：

```bash
sudo ./xray-install-production.sh upgrade \
  --version 26.3.27
```

首次安装指定版本：

```bash
sudo ./xray-install-production.sh install \
  --version v26.3.27
```

`--version` 同样可以用于降级。

恢复跟随最新稳定版：

```bash
sudo ./xray-install-production.sh upgrade \
  --version latest
```

## systemd 服务

脚本生成：

```text
/etc/systemd/system/xray.service
```

默认核心配置类似：

```ini
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=xray
Group=xray

ExecStartPre=/usr/local/bin/xray run -test -confdir "/usr/local/etc/xray"
ExecStart=/usr/local/bin/xray run -confdir "/usr/local/etc/xray"

Restart=on-failure
RestartSec=3s
RestartPreventExitStatus=23

TimeoutStopSec=30s
KillSignal=SIGTERM

LimitNPROC=10000
LimitNOFILE=1000000

RuntimeDirectory=xray
RuntimeDirectoryMode=0755
UMask=0027

CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

第一次安装时，如果 `xray` 用户不存在，脚本会自动创建一个无登录权限的系统用户。

指定其他运行用户：

```bash
sudo ./xray-install-production.sh install \
  --user root
```

或：

```bash
sudo ./xray-install-production.sh install \
  --user my-xray
```

如果指定的非 root 用户不存在，脚本会尝试创建该系统用户。

## 仅更新 systemd 配置

不下载安装 Xray，只重新生成 systemd 服务：

```bash
sudo ./xray-install-production.sh service
```

例如修改配置目录：

```bash
sudo ./xray-install-production.sh service \
  --config-dir /etc/xray/conf.d
```

或者修改运行用户：

```bash
sudo ./xray-install-production.sh service \
  --user xray
```

执行前后都会进行配置检测，并重新启动服务。

## 配置检测

可以手动检测整个配置目录：

```bash
/usr/local/bin/xray run \
  -test \
  -confdir /usr/local/etc/xray
```

配置正常会显示：

```text
Configuration OK.
```

脚本在安装或升级时也会自动执行该检查。

配置检测失败时不会继续正常启动新版本。

## 升级保护和回滚

安装或升级的大致流程：

```text
获取目标版本
    ↓
下载 Xray Release
    ↓
下载 .dgst
    ↓
SHA256 校验
    ↓
备份当前 xray 二进制
    ↓
备份当前 xray.service
    ↓
安装新二进制
    ↓
生成 systemd 服务
    ↓
测试多配置文件
    ↓
启动 / 重启 xray.service
    ↓
检查服务状态
```

如果配置测试失败：

```text
恢复旧 Xray 二进制
恢复旧 systemd 服务
```

如果新版本启动失败，同样会尝试恢复旧二进制和旧服务，并重新启动原版本。

> 回滚只针对当前升级过程中的 Xray 二进制和脚本管理的 systemd 服务，不会修改或回滚你的 JSON 配置文件。

## 查看状态

```bash
sudo ./xray-install-production.sh status
```

同时可以直接使用：

```bash
systemctl status xray
```

查看当前 Xray 版本：

```bash
/usr/local/bin/xray -version
```

## 日志

默认不创建 `/var/log/xray`。

查看最近日志：

```bash
journalctl -u xray -n 100 --no-pager
```

实时查看：

```bash
journalctl -u xray -f
```

查看本次启动以来的日志：

```bash
journalctl -u xray -b
```

## GeoData

默认是 **core-only** 模式，不安装：

```text
geoip.dat
geosite.dat
```

如果确实需要 Xray Release 自带的 GeoData，可以显式执行：

```bash
sudo ./xray-install-production.sh install \
  --with-geodata
```

或者升级时：

```bash
sudo ./xray-install-production.sh upgrade \
  --with-geodata
```

此时才会创建：

```text
/usr/local/share/xray/
├── geoip.dat
└── geosite.dat
```

同时 systemd 服务会增加：

```ini
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
```

`--without-geodata` 仍然可用，但只是兼容参数，因为默认本身就是不安装 GeoData：

```bash
sudo ./xray-install-production.sh upgrade \
  --without-geodata
```

GeoData 选项不会持久化。一次使用 `--with-geodata` 不会导致以后普通 `upgrade` 自动继续更新 GeoData。

## 下载代理

GitHub 访问需要代理时：

```bash
sudo ./xray-install-production.sh upgrade \
  --proxy socks5h://127.0.0.1:1080
```

HTTP 代理：

```bash
sudo ./xray-install-production.sh upgrade \
  --proxy http://127.0.0.1:8080
```

代理参数只影响脚本通过 `curl` 进行的下载请求。

## 配置状态文件

脚本使用：

```text
/etc/xray-install.conf
```

保存：

```bash
XRAY_CONFIG_DIR=/usr/local/etc/xray
XRAY_INSTALL_USER=xray
```

文件权限为：

```text
600
```

因此后续可以直接：

```bash
sudo ./xray-install-production.sh upgrade
```

而无需重复指定配置目录和运行用户。

## 常用命令

```bash
# 安装最新版 Xray-core
sudo ./xray-install-production.sh install

# 使用自定义多配置目录
sudo ./xray-install-production.sh install \
  --config-dir /etc/xray/conf.d

# 升级最新版
sudo ./xray-install-production.sh upgrade

# 指定版本
sudo ./xray-install-production.sh upgrade \
  --version v26.3.27

# 强制重新安装
sudo ./xray-install-production.sh upgrade \
  --force

# 仅重新生成 systemd 服务
sudo ./xray-install-production.sh service

# 查看状态
sudo ./xray-install-production.sh status

# 查看日志
journalctl -u xray -f

# 测试配置
/usr/local/bin/xray run \
  -test \
  -confdir /usr/local/etc/xray
```

## 参数

```text
Actions:
  install
      安装 Xray；如果已安装，也可作为升级使用。

  upgrade
      升级或降级到最新版本/指定版本。

  service
      只重新生成 systemd 服务，不下载 Xray。

  status
      查看当前版本和 systemd 服务状态。

Options:
  --version <latest|VERSION>
      指定目标版本。

  --config-dir <DIR>
      指定多配置文件目录。
      默认：/usr/local/etc/xray

  --user <USER>
      指定 systemd 运行用户。
      默认：xray

  --proxy <URL>
      指定 curl 下载代理。

  --with-geodata
      显式安装 geoip.dat 和 geosite.dat。

  --without-geodata
      不安装 GeoData；当前默认行为。

  --force
      即使版本相同也重新下载安装。

  -h, --help
      显示帮助。
```

## 注意事项

1. 配置目录必须使用绝对路径。
2. 安装和升级需要 root 权限。
3. 脚本默认管理 `/etc/systemd/system/xray.service`，再次执行可能重写该文件。
4. 如需额外自定义 systemd 参数，建议使用 systemd drop-in，而不是直接长期修改主 service 文件：

```bash
sudo systemctl edit xray
```

例如：

```ini
[Service]
RestartSec=5s
```

5. JSON 配置文件由用户自行维护，脚本不会覆盖已有 `.json` 文件。
6. 如果配置依赖 `geoip:` 或 `geosite:` 规则，请自行提供 GeoData，或执行时显式使用 `--with-geodata`。
7. 升级会执行一次 `systemctl restart xray`，因此不是零中断升级。

## License

本脚本用于安装和管理 [XTLS/Xray-core](https://github.com/XTLS/Xray-core)。

Xray-core 及其相关组件的许可证以各自上游项目为准。
