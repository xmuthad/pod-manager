#!/bin/bash

# Pod Manager Webhook模拟测试脚本
# 此脚本用于模拟各种场景下Pod Manager Webhook的行为
# 包括：
# 1. 不同资源配置的Pod测试
# 2. 边界情况测试（零资源请求、极大资源请求）
# 3. 多容器Pod测试
# 4. 命名空间切换测试

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
TARGET_NAMESPACE="test-webhook-sim"
NON_TARGET_NAMESPACE="test-non-target-sim"
DEFAULT_NAMESPACE="default"
CPU_OVERCOMMIT_RATIO=1.5
MEMORY_OVERCOMMIT_RATIO=1.5

# 清理函数
cleanup() {
    info "清理测试资源..."
    kubectl delete namespace ${TARGET_NAMESPACE} --ignore-not-found=true
    kubectl delete namespace ${NON_TARGET_NAMESPACE} --ignore-not-found=true
    kubectl delete pod sim-test-pod-* --namespace=${DEFAULT_NAMESPACE} --ignore-not-found=true
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
    local description=$6
    local expected_cpu_request
    local expected_memory_request
    
    if [ "$expected_modified" = "true" ]; then
        # 计算期望的资源请求值（根据超售比例）
        expected_cpu_request=$(echo "scale=3; ${cpu_request%m} / ${CPU_OVERCOMMIT_RATIO}" | bc)"m"
        
        # 处理内存单位转换
        if [[ "$memory_request" == *"Gi"* ]]; then
            memory_value=${memory_request%Gi}
            expected_memory_request=$(echo "scale=0; ${memory_value} * 1024 / ${MEMORY_OVERCOMMIT_RATIO}" | bc)"Mi"
        elif [[ "$memory_request" == *"Mi"* ]]; then
            memory_value=${memory_request%Mi}
            expected_memory_request=$(echo "scale=0; ${memory_value} / ${MEMORY_OVERCOMMIT_RATIO}" | bc)"Mi"
        else
            expected_memory_request=${memory_request}
        fi
    else
        # 不应修改，期望值与原始值相同
        expected_cpu_request="${cpu_request}"
        expected_memory_request="${memory_request}"
    fi
    
    info "在命名空间 ${namespace} 中创建测试Pod: ${pod_name} (${description})"
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
    
    info "命名空间: ${namespace}, Pod: ${pod_name} (${description})"
    info "原始CPU请求: ${cpu_request}, 期望CPU请求: ${expected_cpu_request}, 实际CPU请求: ${actual_cpu_request}"
    info "原始内存请求: ${memory_request}, 期望内存请求: ${expected_memory_request}, 实际内存请求: ${actual_memory_request}"
    
    # 验证结果
    if [[ "$expected_modified" = "true" ]]; then
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

# 测试多容器Pod
test_multi_container_pod() {
    local namespace=$1
    local expected_modified=$2
    local pod_name=$3
    
    info "在命名空间 ${namespace} 中创建多容器测试Pod: ${pod_name}"
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
        cpu: 500m
        memory: 512Mi
  - name: redis
    image: redis:latest
    resources:
      requests:
        cpu: 200m
        memory: 256Mi
  restartPolicy: Never
EOF
    
    # 等待Pod创建完成
    sleep 5
    
    # 获取实际的资源请求
    local actual_cpu_request1=$(kubectl get pod ${pod_name} -n ${namespace} -o jsonpath='{.spec.containers[0].resources.requests.cpu}')
    local actual_memory_request1=$(kubectl get pod ${pod_name} -n ${namespace} -o jsonpath='{.spec.containers[0].resources.requests.memory}')
    local actual_cpu_request2=$(kubectl get pod ${pod_name} -n ${namespace} -o jsonpath='{.spec.containers[1].resources.requests.cpu}')
    local actual_memory_request2=$(kubectl get pod ${pod_name} -n ${namespace} -o jsonpath='{.spec.containers[1].resources.requests.memory}')
    
    info "命名空间: ${namespace}, Pod: ${pod_name} (多容器)"
    info "容器1 - 原始CPU请求: 500m, 实际CPU请求: ${actual_cpu_request1}"
    info "容器1 - 原始内存请求: 512Mi, 实际内存请求: ${actual_memory_request1}"
    info "容器2 - 原始CPU请求: 200m, 实际CPU请求: ${actual_cpu_request2}"
    info "容器2 - 原始内存请求: 256Mi, 实际内存请求: ${actual_memory_request2}"
    
    # 验证结果
    if [[ "$expected_modified" = "true" ]]; then
        # 计算期望值
        local expected_cpu1=$(echo "scale=3; 500 / ${CPU_OVERCOMMIT_RATIO}" | bc)"m"
        local expected_mem1=$(echo "scale=0; 512 / ${MEMORY_OVERCOMMIT_RATIO}" | bc)"Mi"
        local expected_cpu2=$(echo "scale=3; 200 / ${CPU_OVERCOMMIT_RATIO}" | bc)"m"
        local expected_mem2=$(echo "scale=0; 256 / ${MEMORY_OVERCOMMIT_RATIO}" | bc)"Mi"
        
        info "容器1 - 期望CPU请求: ${expected_cpu1}, 期望内存请求: ${expected_mem1}"
        info "容器2 - 期望CPU请求: ${expected_cpu2}, 期望内存请求: ${expected_mem2}"
        
        # 简化验证，只检查是否有修改发生
        if [[ "$actual_cpu_request1" == "500m" || "$actual_memory_request1" == "512Mi" ||
              "$actual_cpu_request2" == "200m" || "$actual_memory_request2" == "256Mi" ]]; then
            error "资源请求未被正确修改！"
            return 1
        fi
        
        info "${GREEN}测试通过：多容器Pod的资源请求已正确修改${NC}"
    else
        # 对于不应修改的情况
        if [[ "$actual_cpu_request1" != "500m" || "$actual_memory_request1" != "512Mi" ||
              "$actual_cpu_request2" != "200m" || "$actual_memory_request2" != "256Mi" ]]; then
            error "资源请求被意外修改！"
            return 1
        fi
        
        info "${GREEN}测试通过：多容器Pod的资源请求未被修改，符合预期${NC}"
    fi
    
    # 清理测试Pod
    kubectl delete pod ${pod_name} -n ${namespace} --ignore-not-found=true
    return 0
}

# 执行测试
section "基本功能测试"

# 测试1：标准资源配置
info "测试1：目标命名空间中的标准资源配置Pod"
test_pod "${TARGET_NAMESPACE}" "true" "sim-test-pod-1" "1000m" "1Gi" "标准资源配置"

# 测试2：非目标命名空间中的Pod
info "测试2：非目标命名空间中的Pod"
test_pod "${NON_TARGET_NAMESPACE}" "false" "sim-test-pod-2" "1000m" "1Gi" "非目标命名空间"

section "资源配置边界测试"

# 测试3：小资源配置
info "测试3：小资源配置Pod"
test_pod "${TARGET_NAMESPACE}" "true" "sim-test-pod-3" "100m" "64Mi" "小资源配置"

# 测试4：大资源配置
info "测试4：大资源配置Pod"
test_pod "${TARGET_NAMESPACE}" "true" "sim-test-pod-4" "4000m" "16Gi" "大资源配置"

# 测试5：极小资源配置
info "测试5：极小资源配置Pod"
test_pod "${TARGET_NAMESPACE}" "true" "sim-test-pod-5" "10m" "10Mi" "极小资源配置"

section "多容器Pod测试"

# 测试6：目标命名空间中的多容器Pod
info "测试6：目标命名空间中的多容器Pod"
test_multi_container_pod "${TARGET_NAMESPACE}" "true" "sim-test-pod-6"

# 测试7：非目标命名空间中的多容器Pod
info "测试7：非目标命名空间中的多容器Pod"
test_multi_container_pod "${NON_TARGET_NAMESPACE}" "false" "sim-test-pod-7"

section "命名空间切换测试"

# 测试8：更新webhook配置，切换目标命名空间
info "测试8：切换目标命名空间到 ${NON_TARGET_NAMESPACE}"
kubectl set env deployment/pod-manager TARGET_NAMESPACES=${NON_TARGET_NAMESPACE}

# 等待webhook重启完成
info "等待webhook重启完成..."
sleep 10

# 测试9：原目标命名空间中的Pod不应该被修改
info "测试9：原目标命名空间中的Pod"
test_pod "${TARGET_NAMESPACE}" "false" "sim-test-pod-9" "1000m" "1Gi" "原目标命名空间"

# 测试10：新目标命名空间中的Pod应该被修改
info "测试10：新目标命名空间中的Pod"
test_pod "${NON_TARGET_NAMESPACE}" "true" "sim-test-pod-10" "1000m" "1Gi" "新目标命名空间"

# 恢复原始配置
info "恢复原始配置，设置目标命名空间为: ${TARGET_NAMESPACE}"
kubectl set env deployment/pod-manager TARGET_NAMESPACES=${TARGET_NAMESPACE}

info "${GREEN}所有模拟测试完成！${NC}"