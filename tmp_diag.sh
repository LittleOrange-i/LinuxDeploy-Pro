#!/system/bin/sh
D=/data/data/io.github.ganyu256.linuxdeploypro/files/linuxdeploy-cli
export TMPDIR=/data/local/tmp
export PATH="$D/tools:$PATH"
try() {
    name="$1"; url="$2"
    s=$(date +%s)
    if wget -q --no-check-certificate -T 20 -O /dev/null "$url" 2>/dev/null; then
        e=$(date +%s)
        echo "$name: OK $((e-s))s"
    else
        e=$(date +%s)
        echo "$name: FAIL $((e-s))s"
    fi
}
# 约 1MB 的包索引做速度参考
try "aliyun-http " "http://mirrors.aliyun.com/ubuntu-ports/dists/jammy/main/binary-arm64/Packages.gz"
try "aliyun-https" "https://mirrors.aliyun.com/ubuntu-ports/dists/jammy/main/binary-arm64/Packages.gz"
try "ustc-https  " "https://mirrors.ustc.edu.cn/ubuntu-ports/dists/jammy/main/binary-arm64/Packages.gz"
try "tuna-https  " "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/dists/jammy/main/binary-arm64/Packages.gz"
try "huawei-https" "https://repo.huaweicloud.com/ubuntu-ports/dists/jammy/main/binary-arm64/Packages.gz"
