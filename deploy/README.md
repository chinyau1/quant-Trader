# Quant-Trader 远程一键部署

面向新服务器（Ubuntu 22.04 / 24.04、Debian 12）。装 Docker、拉代码、构建镜像、初始化免费行情并启动常驻服务。

本仓为 [guge199205-byte/quant-Trader](https://github.com/guge199205-byte/quant-Trader) 的 fork：<https://github.com/chinyau1/quant-Trader>

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/full-deploy.sh | sudo bash
```

带模型 Key（`sudo` 会丢掉环境变量，用 `env` 传入）：

```bash
curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/full-deploy.sh \
  | sudo env DEEPSEEK_API_KEY='sk-你的key' bash
```

国内访问 GitHub 不稳定时，换镜像仓库地址：

```bash
curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/full-deploy.sh \
  | sudo env QT_REPO_URL='https://gitclone.com/github.com/chinyau1/quant-Trader.git' bash
```

指定分支：

```bash
curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/full-deploy.sh \
  | sudo bash -s -- --ref main
```

默认安装到 `/opt/quant-trader`。首次约 15–30 分钟（拉基础镜像 + 构建 + 行情）。

## 部署完成后

| 服务 | 地址 |
|------|------|
| Arena 竞技场 | `http://<服务器IP>:8092` |
| 交易智能体 dsh | `http://<服务器IP>:8093`（默认 `admin` / `admin123`） |
| API | `http://<服务器IP>:8091` |

密钥写在 `/opt/quant-trader/.env`。改完后：

```bash
cd /opt/quant-trader && docker compose up -d
```

已有 QuantMind 数据时，把 `QUANTMIND_ROOT` 指到仓库根目录（脚本会探测 `/opt/quantmind` 和 `/home/zbox/projects/quantmind`）。本机 Windows 可在 `.env` 写：

```bash
QUANTMIND_QUANTDB_DIR=D:/project/gitee/quantmind/data/quantdb
QUANTMIND_ROOT=D:/project/gitee/quantmind
QUANTMIND_DATA_DIR=D:/project/gitee/quantmind/data
```

## 更新（同一台机器再跑一遍）

```bash
curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/full-deploy.sh | sudo bash
```

会 `git pull`、按需重建镜像；已有 `.env` 和 `data/` 会保留。目录里有未提交改动时加 `--force`。

## 常用变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `QT_PROJECT_DIR` | `/opt/quant-trader` | 部署目录 |
| `QT_REPO_URL` | `https://github.com/chinyau1/quant-Trader.git` | clone 地址 |
| `QT_REF` | `main` | 分支 / tag |
| `QT_DOCKER_MIRROR` | DaoCloud | Docker Hub 加速 |
| `QT_SKIP_BOOTSTRAP` | `false` | `true` 跳过免费行情 |
| `QT_SKIP_BUILD` | `false` | `true` 不重建镜像 |
| `QT_FORCE` | `false` | 覆盖未提交代码 |
| `QT_OPEN_DSH_LAN` | `false` | `true` 把 dsh-proxy 绑到局域网 IP |

手工排障见 [`docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md)。
