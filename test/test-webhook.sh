#!/bin/bash

# Pod Manager Webhook测试脚本
# 此脚本用于测试Pod Manager Webhook的功能，包括：
# 1. 验证资源限制是否正确应用
# 2. 检查webhook是否只对指定命名空间的Pod进行修改
# 3. 测试不同CPU和内存配置的情况

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
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

# 检查kubectl是否可用
if ! command -v kubectl &> /dev/null; then
    error "kubectl命令不可用，请安装kubectl并配置正确的集群访问权限"
    exit 1
fi

# 测试配置
TARGET_NAMESPACE="test-webhook"
NON_TARGET_NAMESPACE="test-non-target"
DEFAULT_NAMESPACE="default"
CPU_OVERCOMMIT_RATIO=1.5
MEMORY_OVERCOMMIT_RATIO=1.5

# 清理函数
cleanup() {
    info "清理测试资源..."
    kubectl delete namespace ${TARGET_NAMESPACE} --ignore-not-found=true
    kubectl delete namespace ${NON_TARGET_NAMESPACE} --ignore-not-found=true
    kubectl delete pod test-pod test-pod-small test-pod-large --namespace=${DEFAULT_NAMESPACE} --ignore-not-found=true
}

# 捕获Ctrl+C信号，执行清理
trap cleanup EXIT

# 创建测试命名空间
info "创建测试命名空间: ${TARGET_NAMESPACE}"
kubectl create namespace ${TARGET_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

info "创建非目标测试命名空间: ${NON_TARGET_NAMESPACE}"
kubectl create namespace ${NON_TARGET_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 更新webhook配置，设置目标命名空间
info "更新webhook配置，设置目标命名空间为: ${TARGET_NAMESPACE}"
kubectl set env deployment/pod-manager TARGET_NAMESPACES=${TARGET_NAMESPACE}

# 等待webhook重启完成
info "等待webhook重启完成..."
sleep 10

# 测试函数：创建Pod并验证资源请求
test_pod() {
    local namespace=$1
    local expected_modified=$2
    local pod_name=$3
    local cpu_request=$4
    local memory_request=$5
    local expected_cpu_request
    local expected_memory_request
    
    if [ "$expected_modified" = "true" ]; then
        # 计算期望的资源请求值（根据超售比例）
        # webhook中CPU计算逻辑是 cpu.MilliValue()/int64(h.config.CPUOvercommitRatio*1000)
        # 这相当于 cpu_milli / (ratio * 1000) 毫核
        cpu_value=${cpu_request%m}
        expected_cpu_value=$(echo "scale=0; ${cpu_value} / (${CPU_OVERCOMMIT_RATIO} * 1000)" | bc)
        # 如果结果为0，设置为1，因为k8s不允许0值的资源请求
        if [ "$expected_cpu_value" = "0" ]; then
            expected_cpu_value=1
        fi
        expected_cpu_request="${expected_cpu_value}m"
        
        # 处理内存单位转换
        # webhook中内存计算逻辑是 mem.Value()/int64(h.config.MemoryOvercommitRatio)
        if [[ "$memory_request" == *"Gi"* ]]; then
            memory_value=${memory_request%Gi}
            # 转换为字节后再除以超售比例
            memory_bytes=$(echo "${memory_value} * 1024 * 1024 * 1024" | bc)
            expected_memory_bytes=$(echo "${memory_bytes} / ${MEMORY_OVERCOMMIT_RATIO}" | bc)
            # 保持原始单位格式
            expected_memory_request=$(echo "scale=3; ${expected_memory_bytes} / (1024 * 1024 * 1024)" | bc)"Gi"
        elif [[ "$memory_request" == *"Mi"* ]]; then
            memory_value=${memory_request%Mi}
            memory_bytes=$(echo "${memory_value} * 1024 * 1024" | bc)
            expected_memory_bytes=$(echo "${memory_bytes} / ${MEMORY_OVERCOMMIT_RATIO}" | bc)
            # 保持原始单位格式
            expected_memory_request=$(echo "scale=3; ${expected_memory_bytes} / (1024 * 1024)" | bc)"Mi"
        else
            expected_memory_request=${memory_request}
        fi
    else
        # 不应修改，期望值与原始值相同
        expected_cpu_request="${cpu_request}"
        expected_memory_request="${memory_request}"
    fi
    
    info "在命名空间 ${namespace} 中创建测试Pod: ${pod_name}"
    cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${namespace}
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
    local actual_cpu_request=$(kubectl get pod ${pod_name} -n ${namespace} -o jsonpath='{.spec.containers[0].resources.requests.cpu}')
    local actual_memory_request=$(kubectl get pod ${pod_name} -n ${namespace} -o jsonpath='{.spec.containers[0].resources.requests.memory}')
    
    info "命名空间: ${namespace}, Pod: ${pod_name}"
    info "原始CPU请求: ${cpu_request}, 期望CPU请求: ${expected_cpu_request}, 实际CPU请求: ${actual_cpu_request}"
    info "原始内存请求: ${memory_request}, 期望内存请求: ${expected_memory_request}, 实际内存请求: ${actual_memory_request}"
    
    # 验证结果
    if [[ "$expected_modified" = "true" ]]; then
        # 处理CPU值比较
        # 将实际值转换为毫核(m)格式进行比较
        local actual_cpu_value
        local expected_cpu_value=${expected_cpu_request%m}
        
        # 处理可能的单位差异，k8s可能返回"1"而不是"1000m"
        if [[ "$actual_cpu_request" == *"m"* ]]; then
            actual_cpu_value=${actual_cpu_request%m}
        else
            # 如果没有m单位，则是核心数，转换为毫核
            actual_cpu_value=$(echo "${actual_cpu_request} * 1000" | bc)
        fi
        
        # 计算差异并使用近似比较
        local cpu_diff=$(echo "scale=3; $actual_cpu_value - $expected_cpu_value" | bc)
        local cpu_diff_abs=$(echo "$cpu_diff < 0 ? -$cpu_diff : $cpu_diff" | bc)
        
        if (( $(echo "$cpu_diff_abs > 10" | bc -l) )); then
            error "CPU请求值与期望值相差过大！实际值: $actual_cpu_value, 期望值: $expected_cpu_value"
            return 1
        fi
        
        # 处理内存值比较
        # 将两个值都转换为字节进行比较
        local actual_mem_bytes
        local expected_mem_bytes
        
        # 转换实际内存值为字节
        if [[ "$actual_memory_request" == *"Gi"* ]]; then
            actual_mem_bytes=$(echo "${actual_memory_request%Gi} * 1024 * 1024 * 1024" | bc)
        elif [[ "$actual_memory_request" == *"Mi"* ]]; then
            actual_mem_bytes=$(echo "${actual_memory_request%Mi} * 1024 * 1024" | bc)
        elif [[ "$actual_memory_request" == *"Ki"* ]]; then
            actual_mem_bytes=$(echo "${actual_memory_request%Ki} * 1024" | bc)
        fi
        
        # 转换期望内存值为字节
        if [[ "$expected_memory_request" == *"Gi"* ]]; then
            expected_mem_bytes=$(echo "${expected_memory_request%Gi} * 1024 * 1024 * 1024" | bc)
        elif [[ "$expected_memory_request" == *"Mi"* ]]; then
            expected_mem_bytes=$(echo "${expected_memory_request%Mi} * 1024 * 1024" | bc)
        elif [[ "$expected_memory_request" == *"Ki"* ]]; then
            expected_mem_bytes=$(echo "${expected_memory_request%Ki} * 1024" | bc)
        fi
        
        # 计算差异百分比而不是绝对差异
        local mem_diff_percent=$(echo "scale=2; ($actual_mem_bytes - $expected_mem_bytes) * 100 / $expected_mem_bytes" | bc)
        local mem_diff_percent_abs=$(echo "$mem_diff_percent < 0 ? -$mem_diff_percent : $mem_diff_percent" | bc)
        
        # 允许5%的误差
        if (( $(echo "$mem_diff_percent_abs > 5" | bc -l) )); then
            error "内存请求值与期望值相差过大！实际值: $actual_memory_request, 期望值: $expected_memory_request"
            return 1
        fi
        
        info "${GREEN}测试通过：资源请求已正确修改${NC}"
    else
        # 对于不应修改的情况，直接比较字符串
        if [[ "$actual_cpu_request" != "$expected_cpu_request" ]]; then
            error "CPU请求被意外修改！"
            return 1
        fi
        
        if [[ "$actual_memory_request" != "$expected_memory_request" ]]; then
            error "内存请求被意外修改！"
            return 1
        fi
        
        info "${GREEN}测试通过：资源请求未被修改，符合预期${NC}"
    fi
    
    # 清理测试Pod
    kubectl delete pod ${pod_name} -n ${namespace} --ignore-not-found=true
    return 0
}

# 执行测试
info "开始测试..."

# 测试1：目标命名空间中的Pod应该被修改
info "测试1：目标命名空间中的Pod"
test_pod "${TARGET_NAMESPACE}" "true" "test-pod" "1000m" "1Gi"

# 测试2：非目标命名空间中的Pod不应该被修改
info "测试2：非目标命名空间中的Pod"
test_pod "${NON_TARGET_NAMESPACE}" "false" "test-pod" "1000m" "1Gi"

# 测试3：默认命名空间中的Pod不应该被修改
info "测试3：默认命名空间中的Pod"
test_pod "${DEFAULT_NAMESPACE}" "false" "test-pod" "1000m" "1Gi"

# 测试4：目标命名空间中的小资源Pod
info "测试4：目标命名空间中的小资源Pod"
test_pod "${TARGET_NAMESPACE}" "true" "test-pod-small" "100m" "128Mi"

# 测试5：目标命名空间中的大资源Pod
info "测试5：目标命名空间中的大资源Pod"
test_pod "${TARGET_NAMESPACE}" "true" "test-pod-large" "4000m" "8Gi"

info "${GREEN}所有测试完成！${NC}"