# Quant-Trader 远程部署

面向新服务器（Ubuntu 22.04 / 24.04、Debian 12）。默认目录 `/opt/quant-trader`。

本仓为 [guge199205-byte/quant-Trader](https://github.com/guge199205-byte/quant-Trader) 的 fork：<https://github.com/chinyau1/quant-Trader>

## 选择部署方式

| 方式 | 适用场景 | 入口 |
| --- | --- | --- |
| 在线部署 | 新服务器，装 Docker、拉代码、构建并启动 | `deploy.sh` |
| 一键更新 | 已部署服务器更新代码和常驻服务，**不清除** `data/` `logs/` `.env` | `update.sh` |

`full-deploy.sh` 仍可用，会转发到 `deploy.sh`。

## 在线部署

```bash
curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/deploy.sh | sudo bash
```

带模型 Key（`sudo` 会丢掉环境变量，用 `env` 传入）：

```bash
curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/deploy.sh \
  | sudo env DEEPSEEK_API_KEY='sk-你的key' bash
```

指定分支：

```bash
curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/deploy.sh \
  | sudo bash -s -- --ref main --force
```

首次约 15–30 分钟。完成后：

| 服务 | 地址 |
|------|------|
| Arena 竞技场 | `http://<服务器IP>:8092` |
| 交易智能体 dsh | `http://<服务器IP>:8093`（默认 `admin` / `admin123`） |
| API | `http://<服务器IP>:8091` |

## 一键更新（不清除数据）

```bash
cd /opt/quant-trader
sudo bash deploy/update.sh
```

```bash
sudo bash deploy/update.sh --ref main
sudo bash deploy/update.sh --force
sudo bash deploy/update.sh --no-build
```

更新脚本会 `git fetch`、重建常驻容器，并在远程 `baymax-dsh` 里安装 `@xmanrui/dsh-im`。**不会** `docker compose down -v`，也不会删除 `data/`、`logs/`、`.env`、`dsh/root-dsh`。交易 agent（`--profile agents`）不会被自动拉起。

装完后打开 `http://<服务器IP>:8093` → 设置 → IM机器人。跳过插件：`QT_SKIP_DSH_IM=true`。

## 常用变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `QT_PROJECT_DIR` | `/opt/quant-trader`（update 默认为仓库根） | 部署目录 |
| `QT_REPO_URL` | `https://github.com/chinyau1/quant-Trader.git` | clone 地址 |
| `QT_REF` | `main` | 分支 / tag |
| `QT_DOCKER_MIRROR` | DaoCloud | Docker Hub 加速 |
| `QT_SKIP_BOOTSTRAP` | `false` | `true` 跳过免费行情（仅 deploy.sh） |
| `QT_FORCE` | `false` | 覆盖未提交代码 |

手工排障见 [`docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md)。
