# traffic-guard v1.1.0 — 交互式管理菜单、一键安装、在线升级

## ✨ 新特性

### 一键安装

在 VPS 上执行一条命令，自动下载主脚本、安装并进入配置向导：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YCJE/traffic-guard/main/install.sh)
```

> 没有 curl 时把 `curl -fsSL` 换成 `wget -qO-`。非 root 执行会自动通过 sudo 重新拉取。

### 交互式管理菜单（x-ui 风格）

安装完成后，直接输入 `traffic-guard` 即可打开管理菜单，所有日常操作一站搞定：

```
─────── traffic-guard 管理面板 v1.1.0 ───────
  1. 查看当前用量与状态
  2. 演练检查（dry-run，不会关机）
  3. 立即检查（真实执行，可能触发自动关机！）
  4. 测试通知
  5. 编辑配置
  6. 查看最近日志
  7. 定时监控 启动/停止/重启
  8. 升级到最新版
  9. 卸载 traffic-guard
  0. 退出
```

### 在线升级

`traffic-guard upgrade`（或菜单选 8）从 GitHub 拉取最新版：下载后先做语法校验再原子替换，正在运行的进程不受影响，配置文件与统计数据全部保留。升级后无需重启定时任务，脚本会自动重建。

## 🔧 改进

- 安装路径更改为 `/usr/local/bin/traffic-guard`（命令更短更好记），旧路径 `traffic-guard.sh` 自动清理
- 新增 `install.sh` 引导脚本：自动处理 root/sudo、兼容 curl/wget、下载后做语法校验防止装到坏文件
- 菜单中支持启动/停止/重启定时监控（cron 模式通过重命名任务文件实现，systemd 模式直接控制 timer）
- 非终端环境（脚本/管道调用）下裸命令打印帮助而非进入菜单，避免自动化场景被交互卡住
- 菜单操作均在子 shell 中执行，单个功能报错不会导致整个菜单退出

## 📦 安装与升级

```bash
# 全新安装
bash <(curl -fsSL https://raw.githubusercontent.com/YCJE/traffic-guard/main/install.sh)

# 从 v1.0.0 升级
traffic-guard upgrade
```

## 📝 关于 traffic-guard

按服务商计费口径（上下行取最大值 / 仅上行 / 仅下行 / 双向总和）监控 VPS 周期流量：达到预警阈值推送提醒（Telegram / Server酱 / Bark），达到触发阈值自动关机止损，防止超出流量额度被扣费。支持自定义每月重置日、vnstat 持久化统计（重启不丢计数）、`--dry-run` 演练模式。

**Full Changelog**: https://github.com/YCJE/traffic-guard/compare/v1.0.0...v1.1.0
