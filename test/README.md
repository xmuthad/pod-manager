# Pod Manager Webhook 测试脚本

本目录包含了用于测试 Pod Manager Webhook 功能的各种脚本。这些脚本可以帮助验证 webhook 的资源限制功能是否正常工作，以及在不同场景下的行为是否符合预期。

## 测试脚本说明

### 1. 基础功能测试 (test-webhook.sh)

这个脚本测试 Pod Manager Webhook 的基本功能，包括：
- 验证资源限制是否正确应用到目标命名空间的 Pod
- 检查 webhook 是否只对指定命名空间的 Pod 进行修改
- 测试不同 CPU 和内存配置的情况

使用方法：
```bash
./test-webhook.sh
```

### 2. 模拟测试 (test-webhook-simulation.sh)

这个脚本提供了更全面的测试场景，包括：
- 不同资源配置的 Pod 测试
- 边界情况测试（零资源请求、极大资源请求）
- 多容器 Pod 测试
- 命名空间切换测试

使用方法：
```bash
./test-webhook-simulation.sh
```

### 3. 资源限制测试 (test-pod-limits.sh)

这个脚本专门测试资源限制功能，包括：
- 测试不同超售比例下的资源限制效果
- 测试资源限制的精确度
- 测试资源限制对不同规模 Pod 的影响

使用方法：
```bash
./test-pod-limits.sh
```

### 4. 多命名空间测试 (test-multi-namespaces.sh)

这个脚本测试 webhook 在多个命名空间同时工作的情况，包括：
- 测试多个目标命名空间的配置
- 验证所有目标命名空间中的 Pod 都被正确修改
- 验证非目标命名空间中的 Pod 不受影响

使用方法：
```bash
./test-multi-namespaces.sh
```

## 注意事项

1. 运行测试前，请确保已部署 Pod Manager Webhook 并正常运行
2. 测试脚本会创建临时命名空间和 Pod，测试完成后会自动清理
3. 测试过程中会修改 webhook 的配置，测试完成后会尝试恢复原始配置
4. 如果测试过程中被中断，可能需要手动清理测试资源
5. 所有脚本都需要 kubectl 命令可用，并且有足够的权限操作集群资源

## 测试结果解读

- 绿色 [INFO] 消息表示正常信息输出
- 黄色 [WARN] 消息表示警告信息
- 红色 [ERROR] 消息表示错误信息
- 蓝色 [SECTION] 消息表示测试章节分隔

测试通过时会显示绿色的「测试通过」消息，所有测试完成后会显示「所有测试完成！」消息。