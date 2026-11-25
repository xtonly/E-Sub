<div align="center">

# 🚀 E-Sub

**Sub-Store 前后端分离热更新与 Docker 交互式运维管理脚本**

![Shell Script](https://img.shields.io/badge/Language-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)
![Docker](https://img.shields.io/badge/Container-Docker-2496ED?style=flat-square&logo=docker&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux&logoColor=black)
![Version](https://img.shields.io/badge/Version-v1.2-00ADD8?style=flat-square)

解决官方 `xream/sub-store` 镜像前端更新滞后于后端的问题，提供前后端独立增量检测、零中断热更新、自动随机密钥防护、反代域名适配及数据备份恢复的一站式终端面板。

</div>

---

## ✨ 核心特性

- **⚡ 前后端独立增量同步**：绕过 Docker 镜像打包滞后限制，直连 GitHub Releases 检测前端静态包（防 API 限流机制）并秒级热替换；后端比对镜像底层 `SHA256` 摘要，无更新绝不无故重启容器。
- **🔐 零硬编码动态安全密钥**：安装时基于 `/dev/urandom` 自动生成独享高强度随机 `Path` 密钥并本地加密存储（`600` 权限），支持随时一键重置随机密钥或自定义路径，杜绝订阅泄露。
- **🌐 原生适配反向代理与直连**：首次安装向导及配置中心完美支持绑定自定义反代域名（自动规范化 `https://`），未绑定域名时自动探测公网 IP 直连，顶部直接生成免填参数 `?api=` 一键登录完整链接。
- **💾 自动化数据轮转备份与恢复**：一键打包核心订阅与操作器配置（自动剥离前端缓存与敏感运行配置），严格保留最近 **3 份** 历史备份防止磁盘膨胀，支持按序号停机安全回滚。
- **⏰ 无人值守后台静默更新**：内置 Crontab 定时任务开关，支持每日凌晨 `04:00` 自动静默检测并同步最新前后端版本。
- **🎨 自适应双列终端 UI**：动态测量链接长度自适应延伸边框，实时读取容器本地 API 展示精准的前后端版本号与运行指标。

---

## 📦 一键安装与启动

确保服务器已安装 **Docker** 环境（支持 Debian / Ubuntu / CentOS / Alpine 等主流发行版），使用 `root` 用户执行以下命令：

```bash
curl -fsSL [https://raw.githubusercontent.com/xtonly/E-Sub/main/e-sub.sh](https://raw.githubusercontent.com/xtonly/E-Sub/main/e-sub.sh) -o /usr/local/bin/e-sub && chmod +x /usr/local/bin/e-sub && e-sub
```

> **快捷唤出**：首次运行会自动完成环境依赖检测、初始化配置向导（设置端口与反代域名）并注册系统全局命令。日后在任意目录下直接输入 **`e-sub`**（或兼容指令 `update-sub`）即可随时打开交互式管理面板。

---

## 🖥️ 面板预览与菜单说明

```text
====================================================================================
                       E-Sub (Sub-Store) 交互式管理面板 v1.2
====================================================================================
 运行状态 : 运行中 (端口 10551)         访问模式 : 反代域名
 前端版本 : 2.34.4                      后端版本 : 2.44.30
 自动更新 : 已开启 (04:00 前后端)       数据备份 : 1 / 3 份
------------------------------------------------------------------------------------
 一键登录 : [https://sub.example.com?api=https://sub.example.com/YourRandomSecretPath](https://sub.example.com?api=https://sub.example.com/YourRandomSecretPath)
------------------------------------------------------------------------------------
  1. 安装 / 智能增量更新前后端 (推荐)
  2. 仅强制重下并热更新前端
  3. 强制拉取镜像并重建后端容器
  4. 备份订阅配置数据 (自动保留最近 3 份)
  5. 查看容器状态与实时日志
  6. 开启 / 关闭每日凌晨自动更新
  7. 从备份文件恢复配置数据
  8. 配置管理 (反代域名 / Path 密钥 / 端口)
  0. 退出脚本
====================================================================================
```

### 功能选项详解

| 选项 | 功能名称 | 执行逻辑说明 |
| :---: | :--- | :--- |
| **`1`** | **安装 / 智能增量更新** | 首次部署必选；日常运行时自动比对前端 Tag 与后端镜像 ID，仅在发现新版时下载或重建容器 |
| **`2`** | **仅强制热更新前端** | 忽略本地版本记录，强制重新拉取最新 `dist.zip` 覆盖前端目录，无需重启后端容器，秒级生效 |
| **`3`** | **强制重建后端容器** | 强制拉取最新 `xream/sub-store:latest` 镜像并重新创建容器，自动清理残留悬空旧镜像 |
| **`4`** | **备份订阅配置数据** | 打包 `/etc/sub-store` 核心配置至 `backups` 目录，超出 **3 份** 时自动淘汰最旧的备份文件 |
| **`5`** | **查看状态与实时日志** | 输出 Docker 容器端口映射状态、一键登录链接以及最近 25 行容器标准输出日志 |
| **`6`** | **管理每日自动更新** | 一键添加或移除每日 `04:00` 执行的 `e-sub --auto` 静默更新任务（日志位于 `/var/log/sub-store-update.log`） |
| **`7`** | **从备份恢复配置数据** | 列出历史备份文件供序号选择，自动执行「暂停容器 -> 清理旧配置 -> 解压恢复 -> 重启容器」安全流程 |
| **`8`** | **配置管理中心** | 支持随时设置/清除反代域名、一键重置随机 Path 密钥、自定义 Path 路径及修改宿主机监听端口 |
| **`0`** | **退出脚本** | 安全退出当前管理面板（所有二级子菜单输入均同样支持输入 `0` 中止返回） |

---

## 🌐 反向代理配置示例 (推荐)

若在安装向导或菜单 `[8]` 中绑定了自定义域名（以 `sub.example.com`、宿主机默认映射端口 `10551` 为例），请配置反向代理将流量转发至本地端口：

### 方案 A：Caddy 配置（自动签发 HTTPS 证书，最简推荐）

编辑 `/etc/caddy/Caddyfile`，添加以下配置块后重载服务（`systemctl reload caddy`）：

```caddyfile
sub.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:10551
}
```

### 方案 B：Nginx 配置

在站点配置文件中添加如下 `server` 配置块（请提前备好 SSL 证书路径），测试无误后重载（`nginx -t && systemctl reload nginx`）：

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name sub.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name sub.example.com;

    ssl_certificate     /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.pem;

    client_max_body_size 20m;

    location / {
        proxy_pass [http://127.0.0.1:10551](http://127.0.0.1:10551);
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

---

## 📂 目录结构与常见维护提示

脚本所有持久化文件统一收敛在 `/etc/sub-store` 目录下，结构清晰：

```text
/etc/sub-store/
├── sub-store.json          # Sub-Store 核心订阅、单品、组合及操作器配置文件
├── frontend/               # 独立挂载的最新前端静态网页资源目录
├── backups/                # 自动轮转保留的 tar.gz 历史配置备份包 (最多 3 份)
├── .frontend_version       # 当前本地前端版本号记录文件
└── .e-sub.conf             # 脚本私有配置文件 (端口、随机 Path、反代域名，权限 600)
```

- **前端更新后网页版本号未变化？**
  Sub-Store 前端启用了 PWA（Service Worker）强缓存机制。执行前端更新后，请在浏览器打开页面并按下 `Ctrl + F5`（macOS 为 `Cmd + Shift + R`）强制刷新即可加载新版本；极端情况下可在 `F12` 开发者工具 -> `Application` -> `Storage` 中点击 `Clear site data`。
- **为什么直接打开后端接口地址显示“地址未找到”？**
  后端密钥路径仅供 API 请求调用，并非前端路由页面。日常使用请直接复制面板中的 **「一键登录」** 完整地址（形如 `https://域名?api=https://域名/密钥`）在浏览器打开，前端会自动读取参数完成后端绑定。

---

## 🙏 致谢

- 核心项目支持：[sub-store-org/Sub-Store](https://github.com/sub-store-org/Sub-Store) & [Sub-Store-Front-End](https://github.com/sub-store-org/Sub-Store-Front-End)
- 官方容器镜像：[xream/sub-store](https://hub.docker.com/r/xream/sub-store)
