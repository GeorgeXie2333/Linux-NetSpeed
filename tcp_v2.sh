#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#	System Required: Debian 10+, Ubuntu 20.04+
#	Description: Modern BBR TCP Acceleration Script
#	Version: 2.1.0
#	Updated: 2024
#	Original Author: 千影,cx9208
#	Updated by: AI Assistant
#	Note: Modern kernels (5.x+) have BBR built-in
#=================================================

sh_ver="2.1.0"

# Color definitions
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Yellow_font_prefix="\033[33m"
Blue_font_prefix="\033[34m"
Green_background_prefix="\033[42;37m"
Red_background_prefix="\033[41;37m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Yellow_font_prefix}[注意]${Font_color_suffix}"
Success="${Green_font_prefix}[成功]${Font_color_suffix}"

# Global variables
kernel_version=""
kernel_version_full=""
kernel_major=0
kernel_minor=0
release=""
version=""

# Check if running as root
check_root(){
	if [[ $EUID -ne 0 ]]; then
		echo -e "${Error} 此脚本必须以root权限运行！"
		exit 1
	fi
}

# Check system
check_sys(){
	if [[ -f /etc/os-release ]]; then
		# shellcheck source=/dev/null
		. /etc/os-release
		release="$ID"
		version="$VERSION_ID"
	elif [[ -f /etc/debian_version ]]; then
		release="debian"
		version=$(cut -d. -f1 < /etc/debian_version)
	else
		echo -e "${Error} 无法识别的系统类型！"
		exit 1
	fi
	
	# Normalize release name
	case "$release" in
		ubuntu|debian)
			;;
		*)
			echo -e "${Error} 此脚本仅支持 Debian 和 Ubuntu 系统！"
			exit 1
			;;
	esac
}

# Get kernel version (internal use, no output)
get_kernel_version(){
	kernel_version=$(uname -r | awk -F'-' '{print $1}')
	kernel_version_full=$(uname -r)
	kernel_major=$(echo "$kernel_version" | awk -F'.' '{print $1}')
	kernel_minor=$(echo "$kernel_version" | awk -F'.' '{print $2}')
}

# Display kernel version
show_kernel_version(){
	get_kernel_version
	echo -e "${Info} 当前内核版本: ${Green_font_prefix}${kernel_version_full}${Font_color_suffix}"
}

# Check BBR availability (returns 0 if available)
check_bbr_available(){
	get_kernel_version
	
	# BBR requires kernel 4.9+
	if [[ "$kernel_major" -lt 4 ]] || [[ "$kernel_major" -eq 4 && "$kernel_minor" -lt 9 ]]; then
		return 1
	fi
	
	# Check if BBR is available in the kernel (built-in or module)
	if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
		return 0
	fi
	
	# Try to load BBR module
	if modprobe tcp_bbr 2>/dev/null; then
		return 0
	fi
	
	# Check if module file exists
	if find /lib/modules/"$(uname -r)" -name "tcp_bbr.ko*" 2>/dev/null | grep -q .; then
		return 0
	fi
	
	return 1
}

# Check if kernel supports BBRv2 features (kernel 5.13+ has improved BBR)
check_bbr2_available(){
	get_kernel_version
	
	# BBRv2 improvements are in kernel 5.13+
	if [[ "$kernel_major" -lt 5 ]] || [[ "$kernel_major" -eq 5 && "$kernel_minor" -lt 13 ]]; then
		return 1
	fi
	
	return 0
}

# Check if kernel supports BBRv3 features (kernel 6.1+)
check_bbr3_available(){
	get_kernel_version
	
	if [[ "$kernel_major" -lt 6 ]] || [[ "$kernel_major" -eq 6 && "$kernel_minor" -lt 1 ]]; then
		return 1
	fi
	
	return 0
}

# Remove all acceleration settings
remove_all(){
	echo -e "${Info} 正在清除所有TCP加速配置..."
	
	# Remove sysctl settings related to BBR
	sed -i '/# BBR/d' /etc/sysctl.conf
	sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
	sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
	sed -i '/net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
	sed -i '/net.ipv4.tcp_slow_start_after_idle/d' /etc/sysctl.conf
	
	# Remove empty lines at the end of file
	sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' /etc/sysctl.conf 2>/dev/null
	
	# Apply settings
	sysctl -p >/dev/null 2>&1
	
	# Remove from modules-load if exists
	if [[ -f /etc/modules-load.d/bbr.conf ]]; then
		rm -f /etc/modules-load.d/bbr.conf
	fi
	
	echo -e "${Success} 清除加速配置完成"
	sleep 1
}

# Ensure modules-load.d directory and bbr config
setup_bbr_module_autoload(){
	# Create directory if not exists
	if [[ ! -d /etc/modules-load.d ]]; then
		mkdir -p /etc/modules-load.d
	fi
	
	# Create bbr module config
	echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
}

# Enable BBR
enable_bbr(){
	echo -e "${Info} 正在启用 BBR..."
	show_kernel_version
	
	if ! check_bbr_available; then
		echo -e "${Error} 当前系统不支持 BBR"
		echo -e "${Tip} 请先升级系统内核到 4.9 或更高版本"
		return 1
	fi
	
	remove_all
	
	# Load BBR module
	modprobe tcp_bbr 2>/dev/null
	
	# Configure sysctl
	cat >> /etc/sysctl.conf <<EOF

# BBR TCP Congestion Control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
	
	# Apply settings
	sysctl -p >/dev/null 2>&1
	
	# Verify
	local current_cc
	current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
	if [[ "$current_cc" == "bbr" ]]; then
		echo -e "${Success} BBR 启动成功！"
		setup_bbr_module_autoload
		return 0
	else
		echo -e "${Error} BBR 启动失败！"
		return 1
	fi
}

# Enable BBR with optimizations
enable_bbr_optimized(){
	echo -e "${Info} 正在启用 BBR (优化版)..."
	show_kernel_version
	
	if ! check_bbr_available; then
		echo -e "${Error} 当前系统不支持 BBR"
		echo -e "${Tip} 请先升级系统内核到 4.9 或更高版本"
		return 1
	fi
	
	remove_all
	
	# Load BBR module
	modprobe tcp_bbr 2>/dev/null
	
	# Configure sysctl with optimizations
	cat >> /etc/sysctl.conf <<EOF

# BBR TCP Congestion Control (Optimized)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_slow_start_after_idle=0
EOF
	
	# Apply settings
	sysctl -p >/dev/null 2>&1
	
	# Verify
	local current_cc
	current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
	if [[ "$current_cc" == "bbr" ]]; then
		echo -e "${Success} BBR (优化版) 启动成功！"
		setup_bbr_module_autoload
		return 0
	else
		echo -e "${Error} BBR 启动失败！"
		return 1
	fi
}

# Enable BBRv2/v3 optimized settings
enable_bbr_advanced(){
	echo -e "${Info} 正在检查高级 BBR 支持..."
	show_kernel_version
	
	local bbr_version="BBR"
	if check_bbr3_available; then
		bbr_version="BBRv3"
	elif check_bbr2_available; then
		bbr_version="BBRv2"
	fi
	
	if ! check_bbr_available; then
		echo -e "${Error} 当前系统不支持 BBR"
		return 1
	fi
	
	echo -e "${Info} 将配置 ${Green_font_prefix}${bbr_version}${Font_color_suffix} 优化设置"
	
	remove_all
	
	# Load BBR module
	modprobe tcp_bbr 2>/dev/null
	
	# Configure sysctl for advanced BBR
	cat >> /etc/sysctl.conf <<EOF

# ${bbr_version} TCP Congestion Control (Advanced)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_ecn=1
EOF
	
	# Apply settings
	sysctl -p >/dev/null 2>&1
	
	# Verify
	local current_cc
	current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
	if [[ "$current_cc" == "bbr" ]]; then
		echo -e "${Success} ${bbr_version} 配置完成！"
		setup_bbr_module_autoload
		return 0
	else
		echo -e "${Error} 配置失败！"
		return 1
	fi
}

# Optimize system configuration
optimize_system(){
	echo -e "${Info} 正在优化系统配置..."
	
	# Backup original sysctl.conf if not already backed up
	if [[ ! -f /etc/sysctl.conf.backup ]]; then
		cp /etc/sysctl.conf /etc/sysctl.conf.backup
		echo -e "${Info} 已备份原始配置到 /etc/sysctl.conf.backup"
	fi
	
	# Backup limits.conf if not already backed up
	if [[ ! -f /etc/security/limits.conf.backup ]]; then
		cp /etc/security/limits.conf /etc/security/limits.conf.backup
		echo -e "${Info} 已备份 limits.conf 到 /etc/security/limits.conf.backup"
	fi
	
	# Remove old optimization settings (keep BBR settings)
	local settings_to_remove=(
		"fs.file-max"
		"fs.inotify.max_user_instances"
		"net.ipv4.tcp_syncookies"
		"net.ipv4.tcp_fin_timeout"
		"net.ipv4.tcp_tw_reuse"
		"net.ipv4.tcp_tw_recycle"
		"net.ipv4.tcp_max_syn_backlog"
		"net.ipv4.ip_local_port_range"
		"net.ipv4.tcp_max_tw_buckets"
		"net.ipv4.route.gc_timeout"
		"net.ipv4.tcp_synack_retries"
		"net.ipv4.tcp_syn_retries"
		"net.core.somaxconn"
		"net.core.netdev_max_backlog"
		"net.ipv4.tcp_timestamps"
		"net.ipv4.tcp_max_orphans"
		"net.ipv4.ip_forward"
		"net.ipv6.conf.all.forwarding"
		"net.core.rmem_max"
		"net.core.wmem_max"
		"net.core.rmem_default"
		"net.core.wmem_default"
		"net.ipv4.tcp_rmem"
		"net.ipv4.tcp_wmem"
		"net.ipv4.tcp_mtu_probing"
		"net.ipv4.tcp_fastopen"
		"net.ipv4.tcp_keepalive_time"
		"net.ipv4.tcp_keepalive_intvl"
		"net.ipv4.tcp_keepalive_probes"
	)
	
	for setting in "${settings_to_remove[@]}"; do
		sed -i "/${setting}/d" /etc/sysctl.conf
	done
	
	# Remove optimization comment block
	sed -i '/# System Optimization/d' /etc/sysctl.conf
	sed -i '/# File system/d' /etc/sysctl.conf
	sed -i '/# Network core/d' /etc/sysctl.conf
	sed -i '/# TCP settings/d' /etc/sysctl.conf
	sed -i '/# IP forward/d' /etc/sysctl.conf
	
	# Add optimized settings
	cat >> /etc/sysctl.conf <<EOF

# System Optimization for Modern Linux (2024)
# File system
fs.file-max = 1000000
fs.inotify.max_user_instances = 8192

# Network core settings
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# TCP settings
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_max_orphans = 262144

# IP forward (useful for VPN/proxy)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
	
	# Apply settings
	sysctl -p >/dev/null 2>&1
	
	# Add limits configuration (append, don't overwrite)
	# First remove old entries if they exist
	sed -i '/# TCP Script Optimization/d' /etc/security/limits.conf
	sed -i '/^\*.*nofile.*1000000/d' /etc/security/limits.conf
	sed -i '/^root.*nofile.*1000000/d' /etc/security/limits.conf
	sed -i '/^\*.*nproc.*unlimited/d' /etc/security/limits.conf
	sed -i '/^root.*nproc.*unlimited/d' /etc/security/limits.conf
	
	# Append new limits
	cat >> /etc/security/limits.conf <<EOF

# TCP Script Optimization
*               soft    nofile          1000000
*               hard    nofile          1000000
*               soft    nproc           unlimited
*               hard    nproc           unlimited
root            soft    nofile          1000000
root            hard    nofile          1000000
root            soft    nproc           unlimited
root            hard    nproc           unlimited
EOF
	
	# Add ulimit to profile if not exists
	if ! grep -q "ulimit -SHn 1000000" /etc/profile 2>/dev/null; then
		echo "ulimit -SHn 1000000" >> /etc/profile
	fi
	
	echo -e "${Success} 系统优化完成！"
	echo -e "${Tip} 建议重启系统以使所有配置生效"
}

# Restore default configuration
restore_defaults(){
	echo -e "${Info} 正在恢复默认配置..."
	
	# Restore sysctl.conf
	if [[ -f /etc/sysctl.conf.backup ]]; then
		cp /etc/sysctl.conf.backup /etc/sysctl.conf
		echo -e "${Success} 已恢复 sysctl.conf"
	else
		echo -e "${Tip} 未找到 sysctl.conf 备份文件"
	fi
	
	# Restore limits.conf
	if [[ -f /etc/security/limits.conf.backup ]]; then
		cp /etc/security/limits.conf.backup /etc/security/limits.conf
		echo -e "${Success} 已恢复 limits.conf"
	else
		echo -e "${Tip} 未找到 limits.conf 备份文件"
	fi
	
	# Remove bbr module config
	if [[ -f /etc/modules-load.d/bbr.conf ]]; then
		rm -f /etc/modules-load.d/bbr.conf
	fi
	
	# Remove ulimit from profile
	sed -i '/ulimit -SHn 1000000/d' /etc/profile 2>/dev/null
	
	# Apply settings
	sysctl -p >/dev/null 2>&1
	
	echo -e "${Success} 配置已恢复！"
	echo -e "${Tip} 建议重启系统以使配置生效"
}

# Check current status
check_status(){
	get_kernel_version
	
	echo -e "\n${Blue_font_prefix}╔════════════════════════════════════════╗${Font_color_suffix}"
	echo -e "${Blue_font_prefix}║${Font_color_suffix}          ${Green_font_prefix}系统状态检查${Font_color_suffix}                  ${Blue_font_prefix}║${Font_color_suffix}"
	echo -e "${Blue_font_prefix}╚════════════════════════════════════════╝${Font_color_suffix}"
	
	echo -e "${Info} 操作系统: ${Green_font_prefix}${release} ${version}${Font_color_suffix}"
	echo -e "${Info} 内核版本: ${Green_font_prefix}${kernel_version_full}${Font_color_suffix}"
	
	# Check BBR support level
	local bbr_level="不支持"
	if check_bbr3_available; then
		bbr_level="${Green_font_prefix}BBRv3 (内核 6.1+)${Font_color_suffix}"
	elif check_bbr2_available; then
		bbr_level="${Green_font_prefix}BBRv2 (内核 5.13+)${Font_color_suffix}"
	elif check_bbr_available; then
		bbr_level="${Green_font_prefix}BBRv1 (内核 4.9+)${Font_color_suffix}"
	else
		bbr_level="${Red_font_prefix}不支持 (需要内核 4.9+)${Font_color_suffix}"
	fi
	echo -e "${Info} BBR 支持: ${bbr_level}"
	
	# Check current congestion control
	local current_cc current_qdisc
	current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
	current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
	
	if [[ -n "$current_cc" ]]; then
		if [[ "$current_cc" == "bbr" ]]; then
			echo -e "${Info} 拥塞控制: ${Green_font_prefix}${current_cc}${Font_color_suffix} ✓"
		else
			echo -e "${Info} 拥塞控制: ${Yellow_font_prefix}${current_cc}${Font_color_suffix}"
		fi
	else
		echo -e "${Info} 拥塞控制: ${Red_font_prefix}未配置${Font_color_suffix}"
	fi
	
	if [[ -n "$current_qdisc" ]]; then
		if [[ "$current_qdisc" == "fq" ]]; then
			echo -e "${Info} 队列算法: ${Green_font_prefix}${current_qdisc}${Font_color_suffix} ✓"
		else
			echo -e "${Info} 队列算法: ${Yellow_font_prefix}${current_qdisc}${Font_color_suffix}"
		fi
	else
		echo -e "${Info} 队列算法: ${Red_font_prefix}未配置${Font_color_suffix}"
	fi
	
	# Check if BBR is loaded as module
	if lsmod | grep -q tcp_bbr; then
		echo -e "${Info} BBR 模块: ${Green_font_prefix}已加载${Font_color_suffix} ✓"
	elif [[ "$current_cc" == "bbr" ]]; then
		echo -e "${Info} BBR 模块: ${Green_font_prefix}内核内置${Font_color_suffix} ✓"
	else
		echo -e "${Info} BBR 模块: ${Yellow_font_prefix}未加载${Font_color_suffix}"
	fi
	
	# Available congestion control algorithms
	local available_cc
	available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
	if [[ -n "$available_cc" ]]; then
		echo -e "${Info} 可用算法: ${Green_font_prefix}${available_cc}${Font_color_suffix}"
	fi
	
	echo ""
}

# View current configuration
view_config(){
	echo -e "\n${Blue_font_prefix}╔════════════════════════════════════════╗${Font_color_suffix}"
	echo -e "${Blue_font_prefix}║${Font_color_suffix}          ${Green_font_prefix}当前TCP配置${Font_color_suffix}                  ${Blue_font_prefix}║${Font_color_suffix}"
	echo -e "${Blue_font_prefix}╚════════════════════════════════════════╝${Font_color_suffix}"
	
	echo -e "\n${Green_font_prefix}[拥塞控制相关]${Font_color_suffix}"
	sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "未配置"
	sysctl net.core.default_qdisc 2>/dev/null || echo "未配置"
	sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "未配置"
	
	echo -e "\n${Green_font_prefix}[BBR优化相关]${Font_color_suffix}"
	sysctl net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "net.ipv4.tcp_notsent_lowat = 未配置"
	sysctl net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "net.ipv4.tcp_slow_start_after_idle = 未配置"
	sysctl net.ipv4.tcp_ecn 2>/dev/null || echo "net.ipv4.tcp_ecn = 未配置"
	
	echo -e "\n${Green_font_prefix}[网络缓冲区]${Font_color_suffix}"
	sysctl net.core.rmem_max 2>/dev/null || echo "未配置"
	sysctl net.core.wmem_max 2>/dev/null || echo "未配置"
	sysctl net.ipv4.tcp_rmem 2>/dev/null || echo "未配置"
	sysctl net.ipv4.tcp_wmem 2>/dev/null || echo "未配置"
	
	echo -e "\n${Green_font_prefix}[加载的内核模块]${Font_color_suffix}"
	lsmod | grep -E "bbr|fq" || echo "未加载相关模块"
	
	echo ""
}

# Upgrade kernel
upgrade_kernel(){
	echo -e "${Info} 正在检查内核版本..."
	get_kernel_version
	
	if [[ "$kernel_major" -ge 6 ]]; then
		echo -e "${Success} 当前内核版本已经足够新 (${kernel_version_full})"
		echo -e "${Info} 支持所有 BBR 功能，无需升级"
		return 0
	elif [[ "$kernel_major" -eq 5 && "$kernel_minor" -ge 13 ]]; then
		echo -e "${Success} 当前内核版本较新 (${kernel_version_full})"
		echo -e "${Info} 支持 BBRv2，可选择升级到 6.x 以获得 BBRv3"
	fi
	
	echo -e "${Tip} 当前内核版本: ${kernel_version_full}"
	echo -e "${Info} 升级内核可能会影响系统稳定性，请谨慎操作"
	
	read -r -p "是否要升级内核? [y/N]: " choice
	case "$choice" in
		y|Y)
			if [[ "$release" == "ubuntu" ]]; then
				echo -e "${Info} 正在更新软件包列表..."
				apt-get update
				
				echo -e "${Info} 正在安装最新内核..."
				# Get Ubuntu major version
				local ubuntu_major
				ubuntu_major=$(echo "$version" | cut -d. -f1)
				
				if [[ "$ubuntu_major" -ge 20 ]]; then
					apt-get install -y linux-generic-hwe-"${ubuntu_major}".04 2>/dev/null || apt-get install -y linux-generic
				else
					apt-get install -y linux-generic
				fi
				
				echo -e "${Success} 内核升级完成"
				echo -e "${Tip} 请重启系统以使用新内核"
				
				read -r -p "是否现在重启? [y/N]: " reboot_choice
				case "$reboot_choice" in
					y|Y)
						reboot
						;;
					*)
						echo -e "${Info} 已取消重启"
						;;
				esac
			elif [[ "$release" == "debian" ]]; then
				echo -e "${Info} 正在更新软件包列表..."
				apt-get update
				
				# Get Debian codename
				local codename
				codename=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2)
				if [[ -z "$codename" ]]; then
					codename=$(grep -oP '(?<=VERSION=").*(?=")' /etc/os-release | awk '{print $2}' | tr -d '()')
				fi
				
				echo -e "${Info} 正在安装 backports 内核..."
				if [[ -n "$codename" ]] && [[ ! -f /etc/apt/sources.list.d/backports.list ]]; then
					echo "deb http://deb.debian.org/debian ${codename}-backports main" > /etc/apt/sources.list.d/backports.list
					apt-get update
				fi
				
				if [[ -n "$codename" ]]; then
					apt-get install -y -t "${codename}-backports" linux-image-amd64 2>/dev/null || apt-get install -y linux-image-amd64
				else
					apt-get install -y linux-image-amd64
				fi
				
				echo -e "${Success} 内核升级完成"
				echo -e "${Tip} 请重启系统以使用新内核"
				
				read -r -p "是否现在重启? [y/N]: " reboot_choice
				case "$reboot_choice" in
					y|Y)
						reboot
						;;
					*)
						echo -e "${Info} 已取消重启"
						;;
				esac
			fi
			;;
		*)
			echo -e "${Info} 已取消内核升级"
			;;
	esac
}

# Quick setup - BBR + System optimization
quick_setup(){
	echo -e "${Info} 正在执行一键优化配置..."
	echo -e "${Info} 将启用 BBR 并优化系统参数"
	echo ""
	
	# Enable BBR optimized
	enable_bbr_optimized
	
	if [[ $? -eq 0 ]]; then
		echo ""
		# Optimize system
		optimize_system
		
		echo ""
		echo -e "${Success} 一键优化配置完成！"
		echo -e "${Tip} 建议重启系统以确保所有配置生效"
	else
		echo -e "${Error} 配置过程中出现错误"
	fi
}

# Main menu
show_menu(){
	clear
	check_status
	
	echo -e "
${Green_background_prefix} TCP加速 现代化管理脚本 ${Font_color_suffix} ${Green_font_prefix}[v${sh_ver}]${Font_color_suffix}
${Green_font_prefix}支持 Debian 10+ / Ubuntu 20.04+${Font_color_suffix}

${Blue_font_prefix}━━━━━━━━━━━━ BBR 加速管理 ━━━━━━━━━━━━${Font_color_suffix}
 ${Green_font_prefix}1.${Font_color_suffix} 启用 BBR 加速
 ${Green_font_prefix}2.${Font_color_suffix} 启用 BBR 加速 (优化版)
 ${Green_font_prefix}3.${Font_color_suffix} 启用 BBR 高级版 (自动检测v2/v3)
 ${Green_font_prefix}4.${Font_color_suffix} 禁用所有加速

${Blue_font_prefix}━━━━━━━━━━━━ 系统管理 ━━━━━━━━━━━━━━━━${Font_color_suffix}
 ${Green_font_prefix}5.${Font_color_suffix} 优化系统配置
 ${Green_font_prefix}6.${Font_color_suffix} 查看当前配置
 ${Green_font_prefix}7.${Font_color_suffix} 升级内核 (可选)
 ${Green_font_prefix}8.${Font_color_suffix} 恢复默认配置

${Blue_font_prefix}━━━━━━━━━━━━ 快捷操作 ━━━━━━━━━━━━━━━━${Font_color_suffix}
 ${Green_font_prefix}9.${Font_color_suffix} 一键优化 (BBR + 系统优化)

${Blue_font_prefix}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${Font_color_suffix}
 ${Green_font_prefix}0.${Font_color_suffix} 退出脚本
${Blue_font_prefix}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${Font_color_suffix}
"
	
	read -r -p "请输入数字 [0-9]: " choice
	case "$choice" in
		1)
			enable_bbr
			;;
		2)
			enable_bbr_optimized
			;;
		3)
			enable_bbr_advanced
			;;
		4)
			remove_all
			;;
		5)
			optimize_system
			;;
		6)
			view_config
			;;
		7)
			upgrade_kernel
			;;
		8)
			restore_defaults
			;;
		9)
			quick_setup
			;;
		0)
			echo -e "${Info} 退出脚本"
			exit 0
			;;
		*)
			echo -e "${Error} 请输入正确的数字 [0-9]"
			sleep 2
			;;
	esac
	
	# Return to menu
	echo ""
	read -r -p "按回车键返回主菜单..."
	show_menu
}

# Main execution
main(){
	check_root
	check_sys
	show_menu
}

main
