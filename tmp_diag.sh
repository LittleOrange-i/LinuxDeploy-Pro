#!/system/bin/sh
D=/data/data/io.github.ganyu256.linuxdeploypro/files/linuxdeploy-cli
export TMPDIR=/data/local/tmp
export PATH="$D/tools:$PATH"
echo "=== wget 版本 ==="
wget --version 2>&1 | head -2
echo "=== 主机证书目录 ==="
ls -ld /system/etc/security/cacerts 2>&1 | head -2
echo "=== http 测速（Release 文件） ==="
wget -q -O /dev/null http://mirrors.aliyun.com/ubuntu-ports/dists/jammy/Release && echo "http OK"
echo "=== https（不加 --no-check-certificate） ==="
wget -O /dev/null https://mirrors.aliyun.com/ubuntu-ports/dists/jammy/Release 2>&1 | tail -3
echo "=== https + --no-check-certificate ==="
wget -q --no-check-certificate -O /dev/null https://mirrors.aliyun.com/ubuntu-ports/dists/jammy/Release && echo "https(nocheck) OK"
