# Xray 一键安装脚本

面向 Linux `systemd` 环境的 Xray-core 安装/升级脚本，支持多配置文件目录、SHA256 校验、升级失败自动回滚，并附带一个 VLESS + WebSocket 配置生成器。

## 一键安装

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/w101723/xray-install/main/xray-install-production.sh) install
```

常用变体：

```bash
# 安装/升级到最新发布版（含 pre-release；上游近期版本均标记为 pre-release，默认 latest 可能落后）
sudo bash <(curl -Ls https://raw.githubusercontent.com/w101723/xray-install/main/xray-install-production.sh) install --prerelease

# 安装指定版本（可省略 v，也可用于降级）
sudo bash <(curl -Ls https://raw.githubusercontent.com/w101723/xray-install/main/xray-install-production.sh) install --version v26.7.28

# 自定义配置目录 / 运行用户
sudo bash <(curl -Ls https://raw.githubusercontent.com/w101723/xray-install/main/xray-install-production.sh) install --config-dir /etc/xray/conf.d --user xray

# 需要下载代理时
sudo bash <(curl -Ls https://raw.githubusercontent.com/w101723/xray-install/main/xray-install-production.sh) install --proxy socks5h://127.0.0.1:1080
```

默认安装内容：

```text
/usr/local/bin/xray                     二进制（含 geoip.dat / geosite.dat，--without-geodata 可跳过）
/usr/local/etc/xray/                    配置目录（confdir）
/etc/systemd/system/xray.service        systemd 服务（以 xray 系统用户运行）
/var/log/xray/                          日志目录（access.log / error.log）
/etc/xray-install.conf                  状态文件，记住配置目录/用户等选项
```

## 配置生成（VLESS + WebSocket）

生成一个 VLESS + WebSocket 入站，配合 Nginx 反代使用：

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/w101723/xray-install/main/generate-xray-vless-ws.sh)
```

- 输出到 `/usr/local/etc/xray/10-vless-ws.json`（若设置过自定义 `--config-dir`，会自动跟随）
- 监听 `127.0.0.1:10000`，无 TLS（由 Nginx 终结）
- **每次运行都会生成新的随机 UUID 和 WS 路径**，旧文件自动备份为 `<file>.bak.<时间戳>`
- 文件权限自动设为服务用户可读，生成后重启生效：`sudo systemctl restart xray`

查看当前凭证：

```bash
sudo cat /usr/local/etc/xray/10-vless-ws.json
```

Nginx 反代目标为 `http://127.0.0.1:10000`，`location` 路径填配置中的 `wsSettings.path`，并加上 WebSocket 升级头（`proxy_http_version 1.1`、`Upgrade`、`Connection "upgrade"`）。

## 常用命令

```bash
# 升级到最新稳定版（记住上次指定的目录/用户）
sudo ./xray-install-production.sh upgrade

# 仅重新生成 systemd 服务（改 --config-dir / --user 后使用）
sudo ./xray-install-production.sh service --config-dir /etc/xray/conf.d

# 查看版本与服务状态
sudo ./xray-install-production.sh status

# 强制重装当前版本
sudo ./xray-install-production.sh upgrade --force

# 测试配置
/usr/local/bin/xray run -test -confdir /usr/local/etc/xray
```

本地执行：`git clone` 本仓库后 `sudo ./xray-install-production.sh <action>` 即可。

## 查看日志

```bash
journalctl -u xray -f              # 实时日志
journalctl -u xray -n 100          # 最近 100 行
sudo tail -f /var/log/xray/*.log   # 文件日志
```

## 参数速查

| 参数 | 说明 |
|---|---|
| `install` / `upgrade` | 安装 / 升级降级到目标版本 |
| `service` | 只重新生成 systemd 服务，不下载 |
| `status` | 查看版本和服务状态 |
| `--version <latest\|VERSION>` | 指定版本，`latest` 为最新正式版 |
| `--prerelease` | `latest` 解析为最新发布（含 pre-release） |
| `--config-dir <DIR>` | 配置目录，默认 `/usr/local/etc/xray`，需绝对路径 |
| `--user <USER>` | 服务运行用户，默认 `xray`（不存在时自动创建） |
| `--proxy <URL>` | curl 下载代理 |
| `--with-geodata` / `--without-geodata` | 是否安装 GeoData，默认安装 |
| `--force` | 版本相同时也重装 |

## 行为说明

- 配置目录内所有 `.json` 按文件名顺序合并加载，脚本不会覆盖已有配置；目录中无 `.json` 时创建空的 `00-base.json`。
- 安装/升级时自动将配置目录及其中 `.json` 的属组设为服务用户组并保证组内可读，配置检测失败或服务启动失败会自动回滚二进制和服务（不动 JSON 配置）。
- GeoData 与 `--config-dir`、`--user` 一样持久化到 `/etc/xray-install.conf`，后续普通 `upgrade` 沿用。
- 已装较新预发布版时，普通 `upgrade` 不会静默降级回更旧的正式版，会提示并保留当前版本。
- 需要 root + systemd；升级会重启服务，非零中断。

## License

用于安装和管理 [XTLS/Xray-core](https://github.com/XTLS/Xray-core)，许可证以各自上游项目为准。
