# tls_nextcloud

Auto deployment of NextCloud based on image linuxserver.io/nextcloud, supporting self-signed certificate with SAN attribute for TLS.

## Usage

    $ git clone git@github.com:m666m/tls_nextcloud.git
    $ cd tls_nextcloud

    $ ./deploy.sh -h
    用法: ./deploy.sh [服务器地址]
    [服务器地址] : 可选，用于生成证书的域名或 IP（默认自动生成本机地址）
    本脚本根据 compose.yaml 部署并运行 Nextcloud 容器和配套的 Mariadb 容器，支持重新部署证书。

服务器地址可以是 IP 或域名（FQDN 或短名），用于CA证书SAN属性的域名和ip地址。其它参数都配置在 compose.yaml 中，自行修改即可。

详细使用方法会在部署成功后列出，示例如下：

    $ ./deploy.sh
    证书 CN: myhost.local
    证书 SAN: DNS:myhost.local,DNS:localhost,IP:192.168.1.100,IP:172.17.0.1,IP:127.0.0.1
    ...+......+......+.....+...+...+..........+..+...+.......+......+.....+.    +........... .........................+..    +.............+...+............+............+..+...+.+.....+....+.....    +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    -----
    自签名证书生成完成：证书 ./cert.crt, 私钥 ./cert.key
    启动服务...
    [+] up 2/3
    ...
     ✔ Container tls_nextcloud-app-1           Started     16.6s
    等待 Nextcloud 容器 (tls_nextcloud-app-1) 创建（排队在 db 容器后面）...
    容器已创建。
    检测到 HTTPS 端口映射: 443 -> 443
    等待容器进入健康状态...
    容器已健康。
    注意：即将覆盖容器内的自签名证书（/config/keys/cert.{crt,key}）。
    Successfully copied 3.07kB to tls_nextcloud-app-1:/config/keys/cert.crt
    Successfully copied 3.58kB to tls_nextcloud-app-1:/config/keys/cert.key
    证书已复制到容器内，正在重启 Nextcloud 以应用新证书...
    [+] restart 0/1
     ⠏ Container tls_nextcloud-app-1     Restarting     4.0s

    ============================================================
    部署完成！
    请执行如下操作以正常使用：

    1、将自签名证书添加到浏览器的信任存储，这样浏览器不会再提示安全警告：
      证书文件: /home/user/tls_nextcloud/cert.crt
      或从容器内下载: docker cp tls_nextcloud-app-1:/config/keys/cert.crt ./

    添加方法：
      - Chrome: 设置 -> 隐私和安全 -> 安全 -> 管理证书 -> 导入
      - Firefox: 选项 -> 隐私与安全 -> 证书 -> 查看证书 -> 导入（新版在第一次访问时确认后不会再警告）

    2、浏览器访问 https://myhost.local，初次登录会显示 Nextcloud 初始化页面。
    填写数据库信息请参考 compose.yaml 中的 environment 部分定义的 MYSQL_XXX 变量。
    完成 Nextcloud 的初始化后，重启容器以便缓存设置生效： docker compose restart app

    3、添加 Nextcloud 配置信任域，实现使用域名或ip地址都可以登录。
    请手动将以下地址添加到 Nextcloud 的 trusted_domains 配置中（注意端口 443）：

        myhost.local
        localhost
        192.168.1.100
        172.17.0.1
        127.0.0.1

    或执行以下语句循环添加（在容器内执行 occ 命令，基于当前最大索引）：
      i=$(docker exec --user abc tls_nextcloud-app-1 php /app/www/public/occ config:system:get trusted_domains | wc -l)
      for addr in myhost.local localhost 192.168.1.100 172.17.0.1 127.0.0.1; do
        docker exec --user abc tls_nextcloud-app-1 php /app/www/public/occ config:system:set trusted_domains $((i++)) --value="$addr"
      done

    4、可选：禁用新用户首次登录时自动添加的示例文件和文档：
      执行以下 occ 命令将 skeletondirectory 设置为空：
      docker exec --user abc tls_nextcloud-app-1 php /app/www/public/occ config:system:set     skeletondirectory --value=""
      设置后，新创建的用户将不再拥有默认的示例文件。

    ---------- 日常使用 ----------
    启动仓库容器：
      cd /home/user/tls_nextcloud && docker compose up
    停止仓库容器：
      cd /home/user/tls_nextcloud && docker compose down

    ---------- 重置证书 ----------

    如需重新生成证书（例如更换域名），但保留镜像数据：

      1. 停止容器：cd /home/user/tls_nextcloud && docker compose down

      2. 删除当前的证书文件：rm cert.crt cert.key

      3. 重新运行 deploy.sh

    如果想完全清除所有数据，包括 nextcloud 的设置及数据库中保存的所有已经上传的数据，可删除所有卷：：

      docker compose down -v

    如需远程维护数据库，可使用 ssh 端口转发（请替换 your-username 为实际用户名）：
      ssh -N -L 3307:127.0.0.1:3306 your-username@myhost.local
      然后在本地用数据库客户端连接 127.0.0.1:3307 (用户名/密码请参考 compose.yaml)
    ============================================================
