# 消防视频直播查看系统（轻量版）

手机号登录 + 6路 HLS 直播 + 用户管理。

## 部署（2分钟）

```bash
# 1. 安装依赖
pip install -r requirements.txt

# 2. 启动
python app.py
```

浏览器打开 `http://服务器IP:5000`

## 默认账号

| 手机号 | 角色 |
|---|---|
| 13800138000 | 管理员 |
| 13900139000 | 普通用户 |
| 13700137000 | 普通用户 |

> 登录方式：只输手机号即可，密码即手机号（无需单独密码）

## 功能

- **手机号登录** — 白名单制，未注册手机号无法登录
- **6路视频直播** — HLS 自适应播放，支持 Chrome/Edge/Safari
- **用户管理** — 添加/编辑/禁用/删除用户（仅管理员）
- **登录日志** — 记录每次登录的手机号和 IP

## 视频流地址

| 名称 | 地址 |
|---|---|
| 警情信息 | http://192.168.181.106/live/0/hls.m3u8 |
| 一体化指挥平台 | http://192.168.181.103/live/0/hls.m3u8 |
| 现场图传 | http://192.168.181.105/live/0/hls.m3u8 |
| 无人机画面 | http://192.168.181.104/live/0/hls.m3u8 |
| 社会面监控 | http://192.168.181.101/live/0/hls.m3u8 |
| 全国应急指挥系统 | http://192.168.181.102/live/0/hls.m3u8 |

视频流地址可在数据库 `streams` 表中修改。

## 文件说明

```
video-system/
├── app.py              # 主程序（Flask + SQLite）
├── requirements.txt    # 依赖
├── video.db            # 数据库（首次运行自动创建）
├── templates/
│   ├── login.html      # 登录页
│   ├── dashboard.html  # 视频主页
│   └── users.html      # 用户管理
└── README.md
```

## 生产部署（可选）

用 gunicorn 跑：

```bash
pip install gunicorn
gunicorn -w 2 -b 0.0.0.0:5000 app:app
```

或用 systemd 开机自启：

```ini
# /etc/systemd/system/video.service
[Unit]
Description=Video System
After=network.target

[Service]
WorkingDirectory=/opt/video-system
ExecStart=/usr/bin/python3 /opt/video-system/app.py
Restart=always

[Install]
WantedBy=multi-user.target
```
