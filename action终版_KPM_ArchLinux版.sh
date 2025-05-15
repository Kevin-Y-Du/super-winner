#!/bin/bash

# 参数处理（带默认值）
CPU="${1:-sm8750}"
FEIL="${2:-oneplus_ace5_pro}"
CPUD="${3:-sun}"
ANDROID_VERSION="${4:-android15}"
KERNEL_VERSION="${5:-6.6}"
KERNEL_NAME="${6:--android15-8-g013ec21bba94-abogki383916444}"

# 初始化环境
export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
export CCACHE_NOHASHDIR="true"
export CCACHE_HARDLINK="true"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 错误处理函数
error_exit() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
    exit 1
}

# 目录检查函数
check_directory() {
    if [ ! -d "$1" ]; then
        error_exit "目录不存在: $1"
    fi
}

# 最大化构建空间函数
maximize_build_space() {
    echo -e "${YELLOW}清理系统空间...${NC}"
    sudo rm -rf /usr/share/dotnet
    sudo rm -rf /usr/local/lib/android
    sudo rm -rf /opt/hostedtoolcache/CodeQL
    sudo rm -rf /usr/local/haskell
    sudo apt clean
    sudo rm -rf /tmp/*
    sudo df -h
	cd /root/work/kernel_platform
	tools/bazel clean --expunge
	cd
}

# 清理补丁目录
clean_patches() {
    echo -e "${YELLOW}检查补丁目录...${NC}"
    local dirs=("SukiSU_patch" "susfs4ksu" "kernel_patches")
    for dir in "${dirs[@]}"; do
        if [ -d "$dir" ]; then
            echo -e "删除旧补丁目录: $dir"
            rm -rf "$dir"
        fi
    done
}

# 源码管理函数
manage_source() {
    echo -e "${YELLOW}检查内核源码...${NC}"
    
    # 深度清理残留的.repo目录
    if [[ -d "work/.repo" && ! -f "work/.repo/manifest.xml" ]]; then
        echo -e "${RED}检测到损坏的.repo目录，执行强制清理...${NC}"
        rm -rf work/.repo
    fi

    if [ -d "work/.repo" ]; then
        echo -e "${GREEN}检测到有效源码仓库，执行智能更新...${NC}"
        cd work || error_exit "进入work失败"
        
        # 增强manifest验证
        if [ ! -f ".repo/manifest.xml" ]; then
            echo -e "${YELLOW}检测到manifest丢失，重新初始化...${NC}"
            rm -rf .repo
            repo init -u https://github.com/OnePlusOSS/kernel_manifest.git \
                -b refs/heads/oneplus/$CPU \
                -m $FEIL.xml \
                --depth=1 --repo-url=https://gerrit.googlesource.com/git-repo || error_exit "repo恢复初始化失败"
        fi

        # 分阶段同步策略
        echo -e "${YELLOW}执行预同步验证...${NC}"
        if ! repo manifest -v > /dev/null 2>&1; then
            echo -e "${RED}manifest验证失败，执行深度修复...${NC}"
            repo init --force -u https://github.com/OnePlusOSS/kernel_manifest.git \
                -b refs/heads/oneplus/$CPU \
                -m $FEIL.xml \
                --depth=1 --repo-url=https://gerrit.googlesource.com/git-repo || error_exit "强制修复失败"
        fi

        # 带智能恢复的同步
        for retry in {1..5}; do
            echo -e "${YELLOW}同步尝试 ($retry/5)...${NC}"
            if repo sync -c -j$(nproc --all) --no-tags --force-sync; then
                echo -e "${GREEN}同步成功${NC}"
                break
            else
                echo -e "${RED}同步失败，执行恢复操作...${NC}"
                # 深度清理锁定文件
                find .repo -name '*.lock' -delete
                # 重置所有仓库到已知安全状态
                repo forall -c 'git reset --hard HEAD@{upstream} ; git clean -fdx'
                # 重试前等待网络恢复
                sleep $((retry * 5))
            fi
        done || error_exit "源码同步失败（超过最大重试次数）"
        
        cd ..
    else
        echo -e "${GREEN}初始化新源码仓库...${NC}"
        mkdir -p work && cd work || error_exit "创建work失败"
        
        # 带原子性操作的初始化
        (
            set -e
            trap 'rm -rf .repo' ERR
            repo init -u https://github.com/OnePlusOSS/kernel_manifest.git \
                -b refs/heads/oneplus/$CPU \
                -m $FEIL.xml \
                --depth=1 --repo-url=https://gerrit.googlesource.com/git-repo
            repo sync -c -j$(nproc --all) --no-tags --force-sync
        ) || {
            echo -e "${RED}初始化失败，清理残留文件...${NC}"
            cd ..
            rm -rf work
            error_exit "源码初始化失败"
        }
        
        # 首次初始化清理
        rm -rf /root/work/kernel_platform/common/android/abi_gki_protected_exports_* 2>/dev/null || true
        cd ..
    fi
# 在manage_source函数末尾添加
cd /root/work/kernel_platform
if [ -d "KernelSU" ]; then
    echo -e "${YELLOW}验证KernelSU目录结构...${NC}"
    if [ -L "KernelSU/kernel/kernel" ]; then
        echo -e "${RED}检测到循环符号链接，执行修复...${NC}"
        rm -vf KernelSU/kernel/kernel
        git checkout -- KernelSU/kernel/
    fi
fi
cd ..
}

# 主构建流程
main() {
    echo -e "${GREEN}本脚本改自@偏爱星雾环绕 为ArchLinux提供支持"
    echo -e "请确保已提前配置好git账号和足够的swap空间大小"

    # 初始化目录
    WORKSPACE_ROOT=$(pwd)
    OUTPUT_DIR="${WORKSPACE_ROOT}/kernel_output_dir/"
    echo -e "${GREEN}工作目录：${WORKSPACE_ROOT}${NC}"
    echo -e "${GREEN}产物输出目录：${OUTPUT_DIR}${NC}"
    
    # 第1步：清理系统空间
    maximize_build_space

    # 第2步：判断必要目录存在并创建
    if [ ! -d "/root/work/kernel_platform" ]; then
        sudo mkdir /root/work/kernel_platform
    fi
    
    if [ ! -d ${OUTPUT_DIR} ]; then
        sudo mkdir ${OUTPUT_DIR}
    fi

    # 第3步：下载依赖
    echo -e "${YELLOW}安装系统依赖...${NC}"
    echo “y” | sudo pacman -Syy python3 git curl ccache gcc flex bison bazelopenssl libelf

    # 第4步：安装repo工具
    echo -e "${YELLOW}设置repo工具...${NC}"
    if [ ! -f "/usr/local/bin/repo" ]; then
        curl -s https://storage.googleapis.com/git-repo-downloads/repo > ~/repo
        chmod a+x ~/repo
        sudo mv ~/repo /usr/local/bin/repo
    fi

    # 第5步：源码管理
    clean_patches
    manage_source
    rm -rf /root/work/kernel_platform/common/android/abi_gki_protected_exports_*

    # 第6步：设置SukiSU
    echo -e "${YELLOW}配置SukiSU...${NC}"
    cd /root/work/kernel_platform || error_exit "进入kernel_platform失败"
    curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-dev
    cd KernelSU || error_exit "进入KernelSU失败"
    KSU_VERSION=$(expr $(git rev-list --count main) "+" 10606)
    sed -i "s/DKSU_VERSION=12800/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile
	echo -e "${YELLOW}检查符号链接...${NC}"
	find KernelSU/ -type l -exec ls -l {} \; | awk '{if($11 == $9) exit 1}' 
	if [ $? -ne 0 ]; then
		error_exit "检测到无效符号链接"
	fi
    cd ../../..

    # 第7步：设置susfs
    echo -e "${YELLOW}配置SUSFS...${NC}"
    cd work || error_exit "进入work失败"
    git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-$ANDROID_VERSION-$KERNEL_VERSION
    git clone https://github.com/ExmikoN/SukiSU_patch.git

    # 复制补丁文件
    cp susfs4ksu/kernel_patches/50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch kernel_platform/common/
    cp susfs4ksu/kernel_patches/fs/* kernel_platform/common/fs/
    cp susfs4ksu/kernel_patches/include/linux/* kernel_platform/common/include/linux/

    # 处理lz4k
    echo -e "${YELLOW}应用LZ4K补丁...${NC}"
    cp -r SukiSU_patch/other/lz4k/include/linux/* kernel_platform/common/include/linux
    cp -r SukiSU_patch/other/lz4k/lib/* kernel_platform/common/lib
    cp -r SukiSU_patch/other/lz4k/crypto/* kernel_platform/common/crypto

    # 应用补丁
    cd kernel_platform/common || error_exit "进入common目录失败"
    sed -i 's/-32,12 +32,38/-32,11 +32,37/g' 50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch
    sed -i '/#include <trace\/hooks\/fs.h>/d' 50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch
    patch -p1 < 50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch || true

    cp ../../SukiSU_patch/hooks/syscall_hooks.patch ./
    patch -p1 -F 3 < syscall_hooks.patch || error_exit "应用syscall补丁失败"

    # 第8步：应用lz4kd补丁
    echo -e "${YELLOW}应用LZ4KD补丁...${NC}"
    cp ../../SukiSU_patch/other/lz4k_patch/$KERNEL_VERSION/lz4kd.patch ./
    patch -p1 -F 3 < lz4kd.patch || true

    # 第9步：配置SUSFS
    echo -e "${YELLOW}配置内核选项...${NC}"
    echo -e "\n# SUSFS配置" >> arch/arm64/configs/gki_defconfig
    cat <<EOT >> arch/arm64/configs/gki_defconfig
CONFIG_KSU=y
CONFIG_KPM=y
CONFIG_KSU_SUSFS_SUS_SU=n
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_CRYPTO_LZ4HC=y
CONFIG_CRYPTO_LZ4K=y
CONFIG_CRYPTO_LZ4KD=y
CONFIG_CRYPTO_842=y
EOT

    # 移除check_defconfig
    sed -i 's/check_defconfig//' build.config.gki
    git add -A && git commit -a -m "BUILD Kernel"
    cd ../../..

    # 第10步：设置内核名称
    echo -e "${YELLOW}设置内核标识...${NC}"
    cd work/kernel_platform || error_exit "进入kernel_platform失败"
    check_directory "common/scripts"
    sed -i 's/res="\$res\$(cat "\$file")"/res="'$KERNEL_NAME'"/g' common/scripts/setlocalversion
    cd ../..

    # 第11步：构建内核
    echo -e "${YELLOW}开始内核编译...${NC}"
    cd work/kernel_platform || error_exit "进入kernel_platform失败"
	# 清理残留
	echo -e "${YELLOW}清理符号链接残留...${NC}"
	find kernel_platform/ -type l -name "kernel" -delete
	find kernel_platform/ -type d -empty -delete
    check_directory "tools"
    tools/bazel run --config=fast --config=stamp --lto=thin //common:kernel_aarch64_dist -- --dist_dir=dist
	#tools/bazel run --nofetch --config=fast --config=stamp --lto=thin //common:kernel_aarch64_dist -- --dist_dir=dist

    # 第12步：制作AnyKernel3
    echo -e "${YELLOW}打包内核镜像...${NC}"
    cd /root/work/kernel_platform/dist || error_exit "进入dist目录失败"

    # 克隆AnyKernel3模板
    if [ "$FEIL" = "oneplus_ace5_pro" ]; then
        git clone -b a5p https://github.com/aa123330/AnyKernel3.git --depth=1
    else
        git clone https://github.com/aa123330/AnyKernel3.git --depth=1
    fi

    # 清理并复制内核镜像
    rm -rf AnyKernel3/.git AnyKernel3/push.sh
    cp Image AnyKernel3/

    # 进入AnyKernel3目录执行打包
    echo -e "${YELLOW}正在生成刷机包...${NC}"
    cd AnyKernel3 || error_exit "进入AnyKernel3目录失败"
    cp /root/work/SukiSU_patch/kpm/patch_linux ./
    chmod 777 patch_linux
    ./patch_linux
    rm -rf Image && mv oImage Image
    rm -rf patch_linux
    
    # 生成带时间戳的文件名
    timestamp=$(date +%Y%m%d%H%M)
    output_zip="SuKiSu_${KSU_VERSION}_${FEIL}_${timestamp}.zip"
    
    # 正确打包姿势：在AnyKernel3目录内打包
    zip -r "../${output_zip}" *

    # 移动成品到输出目录
    echo -e "${YELLOW}移动产物到${OUTPUT_DIR}...${NC}"
    sudo mkdir -p "$OUTPUT_DIR"
    sudo mv "../${output_zip}" "$OUTPUT_DIR/"

    # 返回工作目录
    cd "$WORKSPACE_ROOT" || error_exit "返回工作目录失败"

    # 输出完整路径
    final_path="${OUTPUT_DIR}/${output_zip}"
    echo -e "${GREEN}构建完成！刷机包路径：${NC}"
    echo -e "${YELLOW}${final_path}${NC}"

    # 权限修复（如果以sudo运行）
    sudo chown $USER: "$final_path" 2>/dev/null || true
}

# 执行主函数
main "$@"
