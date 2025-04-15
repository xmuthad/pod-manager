#!/bin/bash

# Pod Manager Webhook资源限制测试脚本
# 此脚本用于测试Pod Manager Webhook的资源限制功能，包括：
# 1. 测试不同超售比例下的资源限制效果
# 2. 测试资源限制的精确度
# 3. 测试资源限制对不同规模Pod的影响

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的信息
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

section() {
    echo -e "\n${BLUE}[SECTION] $1 ${NC}"
    echo -e "${BLUE}================${NC}"
}

# 检查kubectl是否可用
if ! command -v kubectl &> /dev/null; then
    error "kubectl命令不可用，请安装kubectl并配置正确的集群访问权限"
    exit 1
fi

# 测试配置
TEST_NAMESPACE="test-pod-limits"

# 清理函数
cleanup() {
    info "清理测试资源..."
    kubectl delete namespace ${TEST_NAMESPACE} --ignore-not-found=true
}

# 捕获Ctrl+C信号，执行清理
trap cleanup EXIT

# 创建测试命名空间
info "创建测试命名空间: ${TEST_NAMESPACE}"
kubectl create namespace ${TEST_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 测试函数：创建Pod并验证资源请求
test_pod_with_ratio() {
    local cpu_ratio=$1
    local memory_ratio=$2
    local pod_name=$3
    local cpu_request=$4
    local memory_request=$5
    local description=$6
    
    # 更新webhook配置，设置超售比例
    info "更新webhook配置，设置CPU超售比例为: ${cpu_ratio}, 内存超售比例为: ${memory_ratio}"
    kubectl set env deployment/pod-manager CPU_OVERCOMMIT_RATIO=${cpu_ratio} MEMORY_OVERCOMMIT_RATIO=${memory_ratio} TARGET_NAMESPACES=${TEST_NAMESPACE}
    
    # 等待webhook重启完成
    info "等待webhook重启完成..."
    sleep 10
    
    # 计算期望的资源请求值
    local expected_cpu_request=$(echo "scale=3; ${cpu_request%m} / ${cpu_ratio}" | bc)"m"
    
    # 处理内存单位转换
    if [[ "$memory_request" == *"Gi"* ]]; then
        memory_value=${memory_request%Gi}
        expected_memory_request=$(echo "scale=0; ${memory_value} * 1024 / ${memory_ratio}" | bc)"Mi"
    elif [[ "$memory_request" == *"Mi"* ]]; then
        memory_value=${memory_request%Mi}
        expected_memory_request=$(echo "scale=0; ${memory_value} / ${memory_ratio}" | bc)"Mi"
    else
        expected_memory_request=${memory_request}
    fi
    
    info "在命名空间 ${TEST_NAMESPACE} 中创建测试Pod: ${pod_name} (${description})"
    cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${TEST_NAMESPACE}
spec:
  containers:
  - name: nginx
    image: nginx:latest
    resources:
      requests:
        cpu: ${cpu_request}
        memory: ${memory_request}
  restartPolicy: Never
EOF
    
    # 等待Pod创建完成
    sleep 5
    
    # 获取实际的资源请求
    local actual_cpu_request=$(kubectl get pod ${pod_name} -n ${TEST_NAMESPACE} -o jsonpath='{.spec.containers[0].resources.requests.cpu}')
    local actual_memory_request=$(kubectl get pod ${pod_name} -n ${TEST_NAMESPACE} -o jsonpath='{.spec.containers[0].resources.requests.memory}')
    
    info "Pod: ${pod_name} (${description}), 超售比例: CPU=${cpu_ratio}, 内存=${memory_ratio}"
    info "原始CPU请求: ${cpu_request}, 期望CPU请求: ${expected_cpu_request}, 实际CPU请求: ${actual_cpu_request}"
    info "原始内存请求: ${memory_request}, 期望内存请求: ${expected_memory_request}, 实际内存请求: ${actual_memory_request}"
    
    # 验证结果
    # 由于浮点数计算和单位转换可能导致的微小差异，这里使用近似比较
    local cpu_value=${actual_cpu_request%m}
    local expected_cpu_value=${expected_cpu_request%m}
    local cpu_diff=$(echo "scale=3; $cpu_value - $expected_cpu_value" | bc)
    local cpu_diff_abs=$(echo "$cpu_diff < 0 ? -$cpu_diff : $cpu_diff" | bc)
    
    if (( $(echo "$cpu_diff_abs > 10" | bc -l) )); then
        error "CPU请求值与期望值相差过大！"
        return 1
    fi
    
    # 内存单位可能不同（Mi vs Gi），转换为相同单位比较
    local mem_value
    local expected_mem_value
    
    if [[ "$actual_memory_request" == *"Gi"* ]]; then
        mem_value=$(echo "${actual_memory_request%Gi} * 1024" | bc)
    elif [[ "$actual_memory_request" == *"Mi"* ]]; then
        mem_value=${actual_memory_request%Mi}
    fi
    
    if [[ "$expected_memory_request" == *"Gi"* ]]; then
        expected_mem_value=$(echo "${expected_memory_request%Gi} * 1024" | bc)
    elif [[ "$expected_memory_request" == *"Mi"* ]]; then
        expected_mem_value=${expected_memory_request%Mi}
    fi
    
    local mem_diff=$(echo "scale=0; $mem_value - $expected_mem_value" | bc)
    local mem_diff_abs=$(echo "$mem_diff < 0 ? -$mem_diff : $mem_diff" | bc)
    
    if (( $(echo "$mem_diff_abs > 10" | bc -l) )); then
        error "内存请求值与期望值相差过大！"
        return 1
    fi
    
    info "${GREEN}测试通过：资源请求已正确修改${NC}"
    
    # 清理测试Pod
    kubectl delete pod ${pod_name} -n ${TEST_NAMESPACE} --ignore-not-found=true
    return 0
}

# 执行测试
section "不同超售比例测试"

# 测试1：标准超售比例 (1.5)
info "测试1：标准超售比例 (1.5)"
test_pod_with_ratio "1.5" "1.5" "test-pod-ratio-1" "1000m" "1Gi" "标准超售比例"

# 测试2：高超售比例 (2.0)
info "测试2：高超售比例 (2.0)"
test_pod_with_ratio "2.0" "2.0" "test-pod-ratio-2" "1000m" "1Gi" "高超售比例"

# 测试3：低超售比例 (1.2)
info "测试3：低超售比例 (1.2)"
test_pod_with_ratio "1.2" "1.2" "test-pod-ratio-3" "1000m" "1Gi" "低超售比例"

# 测试4：无超售 (1.0)
info "测试4：无超售 (1.0)"
test_pod_with_ratio "1.0" "1.0" "test-pod-ratio-4" "1000m" "1Gi" "无超售"

section "不同资源规模测试"

# 恢复标准超售比例
info "恢复标准超售比例 (1.5)"
kubectl set env deployment/pod-manager CPU_OVERCOMMIT_RATIO=1.5 MEMORY_OVERCOMMIT_RATIO=1.5
sleep 10

# 测试5：小规模资源
info "测试5：小规模资源"
test_pod_with_ratio "1.5" "1.5" "test-pod-small" "100m" "128Mi" "小规模资源"

# 测试6：中规模资源
info "测试6：中规模资源"
test_pod_with_ratio "1.5" "1.5" "test-pod-medium" "500m" "512Mi" "中规模资源"

# 测试7：大规模资源
info "测试7：大规模资源"
test_pod_with_ratio "1.5" "1.5" "test-pod-large" "2000m" "4Gi" "大规模资源"

# 测试8：超大规模资源
info "测试8：超大规模资源"
test_pod_with_ratio "1.5" "1.5" "test-pod-xlarge" "8000m" "16Gi" "超大规模资源"

section "不同CPU/内存超售比例组合测试"

# 测试9：CPU高超售，内存低超售
info "测试9：CPU高超售 (2.0)，内存低超售 (1.2)"
test_pod_with_ratio "2.0" "1.2" "test-pod-combo-1" "1000m" "1Gi" "CPU高超售，内存低超售"

# 测试10：CPU低超售，内存高超售
info "测试10：CPU低超售 (1.2)，内存高超售 (2.0)"
test_pod_with_ratio "1.2" "2.0" "test-pod-combo-2" "1000m" "1Gi" "CPU低超售，内存高超售"

# 恢复原始配置
info "恢复原始配置，设置标准超售比例 (1.5)"
kubectl set env deployment/pod-manager CPU_OVERCOMMIT_RATIO=1.5 MEMORY_OVERCOMMIT_RATIO=1.5

info "${GREEN}所有资源限制测试完成！${NC}"