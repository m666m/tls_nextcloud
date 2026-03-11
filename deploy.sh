#!/bin/bash
set -e

# 用法说明
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "用法: $0 [服务器地址]"
    echo "   [服务器地址] : 可选，用于生成证书的域名或 IP（默认自动生成本机地址）"
    echo "本脚本根据 compose.yaml 部署并运行 Nextcloud 容器和配套的 Mariadb 容器，支持重新部署证书。"
    exit 0
fi

SERVER_ADDR="${1:-}"  # 可选参数，传递给 _ssca.sh

# 证书文件路径
CERT_CRT="./cert.crt"
CERT_KEY="./cert.key"

# 检查证书文件是否已存在，存在则报错退出（若想覆盖需手动删除）
if [ -f "$CERT_CRT" ] || [ -f "$CERT_KEY" ]; then
    echo "错误：当前目录下已存在 cert.crt 或 cert.key 文件。"
    echo "如需重新生成证书，请先手动删除这两个文件然后运行本脚本。"
    exit 1
fi

# 检查 compose.yaml 是否存在
if [ ! -f "compose.yaml" ]; then
    echo "错误：未找到 compose.yaml 文件"
    exit 1
fi

# 检查辅助脚本是否存在
if [ ! -f "./_ssca.sh" ]; then
    echo "错误：未找到 _ssca.sh 文件，请确保它与 deploy.sh 位于同一目录。"
    exit 1
fi

# 加载 _ssca.sh，传入服务器地址参数（如果有）
source ./_ssca.sh "$SERVER_ADDR"

echo "证书 CN: $_ssca_CN"
echo "证书 SAN: $_ssca_SAN"

# 生成包含 SAN 的自签名证书（显式添加 CA:TRUE 确保可作为根证书导入）
openssl req -x509 -newkey rsa:2048 -noenc \
    -keyout "$CERT_KEY" \
    -out "$CERT_CRT" \
    -days 3650 \
    -subj "/CN=${_ssca_CN}" \
    -addext "subjectAltName = ${_ssca_SAN}" \
    -addext "basicConstraints = CA:TRUE"

echo "自签名证书生成完成：证书 $CERT_CRT, 私钥 $CERT_KEY"

# 设置宿主机文件权限
chmod 644 "$CERT_CRT"
chmod 600 "$CERT_KEY"

# 启动服务（如果尚未运行则启动，已运行则无影响）
echo "启动服务..."
docker compose up -d

# 获取项目名（基于当前目录名）
PROJECT_NAME=$(basename "$(pwd)")
# 构造预期的 app 容器名（Compose v2 格式：项目名-服务名-索引）
APP_CONTAINER="${PROJECT_NAME}-app-1"

# ==================== 等待容器创建 ====================
echo "等待 Nextcloud 容器 ($APP_CONTAINER) 创建（排队在 db 容器后面）..."
timeout=60
elapsed=0
while [ $elapsed -lt $timeout ]; do
    if docker inspect "$APP_CONTAINER" >/dev/null 2>&1; then
        echo "容器已创建。"
        break
    fi
    sleep 2
    elapsed=$((elapsed+2))
done

if [ $elapsed -ge $timeout ]; then
    echo "错误：等待容器创建超时（${timeout}秒）"
    exit 1
fi

# ==================== 获取主机端口 ====================
# 使用 docker compose port 获取实际映射的主机端口（更可靠）
HOST_PORT=""
if docker compose port app 443 >/dev/null 2>&1; then
    HOST_PORT=$(docker compose port app 443 | cut -d: -f2)
    echo "检测到 HTTPS 端口映射: $HOST_PORT -> 443"
else
    # 回退到从 compose.yaml 解析（兼容性备用）
    HOST_PORT=$(grep -A30 '^  app:' compose.yaml | grep -E '^\s*-\s*"?[0-9]+:443"?$' | head -1 | sed -E 's/^\s*-\s*"?([0-9]+):443"?$/\1/')
    if [ -n "$HOST_PORT" ]; then
        echo "从 compose.yaml 解析到 HTTPS 端口映射: $HOST_PORT -> 443"
    else
        HOST_PORT="443"
        echo "警告：未能获取端口映射，将使用默认端口 443。"
    fi
fi

# 构建基础 URL 和端口后缀
if [ "$HOST_PORT" = "443" ]; then
    BASE_URL="https://${_ssca_CN}"
    PORT_SUFFIX=""
else
    BASE_URL="https://${_ssca_CN}:${HOST_PORT}"
    PORT_SUFFIX=":${HOST_PORT}"
fi

# ==================== 等待容器健康 ====================
echo "等待容器进入健康状态..."
timeout=120
elapsed=0
while [ $elapsed -lt $timeout ]; do
    health=$(docker inspect --format='{{.State.Health.Status}}' "$APP_CONTAINER" 2>/dev/null || echo "starting")
    if [ "$health" = "healthy" ]; then
        echo "容器已健康。"
        break
    fi
    sleep 3
    elapsed=$((elapsed+3))
done

if [ $elapsed -ge $timeout ]; then
    echo "错误：等待容器健康超时（${timeout}秒）"
    exit 1
fi

# 检查容器内证书目录是否存在
if ! docker exec "$APP_CONTAINER" test -d /config/keys; then
    echo "错误：容器内 /config/keys 目录不存在，请确认镜像版本是否正确。"
    exit 1
fi

echo "注意：即将覆盖容器内的自签名证书（/config/keys/cert.{crt,key}）。"

# 复制证书到容器
docker cp "$CERT_CRT" "$APP_CONTAINER":/config/keys/cert.crt
docker cp "$CERT_KEY" "$APP_CONTAINER":/config/keys/cert.key

# 设置容器内权限（容器内用户 abc 的 uid 为 1000）
docker exec "$APP_CONTAINER" chown abc:abc /config/keys/cert.crt /config/keys/cert.key
docker exec "$APP_CONTAINER" chmod 644 /config/keys/cert.crt
docker exec "$APP_CONTAINER" chmod 600 /config/keys/cert.key

echo "证书已复制到容器内，正在重启 Nextcloud 以应用新证书..."
docker compose restart app

# ==================== 从 _ssca 变量中提取地址，用于后续提示 ====================
ADDRESSES=()
for dns in $_ssca_SAN_DNS; do
    ADDRESSES+=("$dns")
done
for ip in $_ssca_SAN_IP; do
    ADDRESSES+=("$ip")
done

# ==================== 输出浏览器信任提示 ====================
echo ""
echo "============================================================"
echo "部署完成！"
echo "请执行如下操作以正常使用："
echo ""
echo "1、将自签名证书添加到浏览器的信任存储，这样浏览器不会再提示安全警告："
echo "  证书文件: $(realpath "$CERT_CRT")"
echo "  或从容器内下载: docker cp $APP_CONTAINER:/config/keys/cert.crt ./"
echo ""
echo "添加方法："
echo "  - Chrome: 设置 -> 隐私和安全 -> 安全 -> 管理证书 -> 导入"
echo "  - Firefox: 选项 -> 隐私与安全 -> 证书 -> 查看证书 -> 导入（新版在第一次访问时确认后不会再警告）"
echo ""

# ==================== 数据库初始化提示 ====================
echo "2、浏览器访问 $BASE_URL，初次登录会显示 Nextcloud 初始化页面。"
echo "填写数据库信息请参考 compose.yaml 中的 environment 部分定义的 MYSQL_XXX 变量。"
echo "完成 Nextcloud 的初始化后，重启容器以便缓存设置生效： docker compose restart app"
echo ""

# ==================== 手动添加信任域 ====================
echo "3、添加 Nextcloud 配置信任域，实现使用域名或 IP 地址都可以登录。"
echo "请手动将以下地址添加到 Nextcloud 的 trusted_domains 配置中（注意端口 $HOST_PORT）："
echo ""
for addr in "${ADDRESSES[@]}"; do
    echo "    $addr${PORT_SUFFIX}"
done
echo ""
echo "或执行以下语句循环添加（在容器内执行 occ 命令，基于当前最大索引）："
echo "  i=\$(docker exec --user abc $APP_CONTAINER php /app/www/public/occ config:system:get trusted_domains | wc -l)"
echo "  for addr in ${ADDRESSES[*]}; do"
echo "    docker exec --user abc $APP_CONTAINER php /app/www/public/occ config:system:set trusted_domains \$((i++)) --value=\"\$addr${PORT_SUFFIX}\""
echo "  done"
echo ""

# ==================== 可选：禁用默认的 skeleton 目录 ====================
echo "4、可选：禁用新用户首次登录时自动添加的示例文件和文档："
echo "  执行以下 occ 命令将 skeletondirectory 设置为空："
echo "  docker exec --user abc $APP_CONTAINER php /app/www/public/occ config:system:set skeletondirectory --value=\"\""
echo "  设置后，新创建的用户将不再拥有默认的示例文件。"
echo ""

echo "---------- 日常使用 ----------"
echo "启动仓库容器："
echo "  cd $(pwd) && docker compose up"
echo "停止仓库容器："
echo "  cd $(pwd) && docker compose down"
echo ""

echo "---------- 重置证书 ----------"
echo ""
echo "如需重新生成证书（例如更换域名），但保留镜像数据："
echo ""
echo "  1. 停止容器：cd $(pwd) && docker compose down"
echo ""
echo "  2. 删除当前的证书文件：rm cert.crt cert.key"
echo ""
echo "  3. 重新运行 deploy.sh"
echo ""
echo "如果想完全清除所有数据，包括 nextcloud 的设置及数据库中保存的所有已经上传的数据，可删除所有卷："
echo ""
echo "  docker compose down -v"
echo ""

# ==================== 远程数据库维护提示 ====================
echo "如需远程维护数据库，可使用 ssh 端口转发（请替换 your-username 为实际用户名）："
echo "  ssh -N -L 3307:127.0.0.1:3306 your-username@$_ssca_CN"
echo "  然后在本地用数据库客户端连接 127.0.0.1:3307 (用户名/密码请参考 compose.yaml)"
echo "============================================================"
