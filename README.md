# Pod Manager

一个Kubernetes准入控制器，用于管理Pod的资源分配和超售比例。

## 项目结构

```
.
├── cmd/                # 程序入口
│   └── webhook/       # webhook服务器
├── pkg/                # 核心逻辑包
│   ├── admission/     # 准入控制逻辑
│   ├── cert/         # 证书生成和管理
│   └── config/       # 配置管理
├── internal/          # 内部工具函数
│   └── utils/        # 通用工具
├── deployment/        # Kubernetes部署文件
└── README.md         # 项目文档
```

## 功能特性

- 自动生成TLS证书
- Pod资源请求的动态调整
- 可配置的CPU和内存超售比例
- 支持通过命令行参数进行配置

## 构建和运行

### 本地构建

```bash
# 构建
go build -o pod-manager cmd/webhook/main.go

# 运行
./pod-manager --cpu-ratio 1.5 --mem-ratio 1.5
```

### 构建Docker镜像

```bash
# 构建镜像，镜像名为pod-manager
docker build -t pod-manager:latest .

# 添加版本标签（推荐）
docker tag pod-manager:latest pod-manager:v1.0.0

# 推送到镜像仓库（可选，替换为您的镜像仓库地址）
# docker push <your-registry>/pod-manager:v1.0.0
```

## 部署到Kubernetes

### 准备部署文件

在部署前，请确保修改`deployment.yaml`中的镜像名称：

```yaml
containers:
  - name: webhook
    image: pod-manager:v1.0.0  # 修改为您的镜像名称和版本
```

### 部署RBAC配置

由于Pod Manager需要创建和管理MutatingWebhookConfiguration资源，必须先部署RBAC配置以授予必要的权限：

```bash
# 部署RBAC配置
kubectl apply -f rbac.yaml
```

### 部署应用

```bash
# 创建部署
kubectl apply -f deployment.yaml

# 检查部署状态
kubectl get pods -l app=pod-manager
```

## 配置说明

### 环境变量配置

在`deployment.yaml`中可以通过环境变量配置以下参数：

| 环境变量 | 说明 | 默认值 |
|---------|------|-------|
| CPU_OVERCOMMIT_RATIO | CPU资源超售比例 | 1.5 |
| MEMORY_OVERCOMMIT_RATIO | 内存资源超售比例 | 1.5 |
| TARGET_NAMESPACES | 目标命名空间（多个用逗号分隔，为空表示所有命名空间） | "" |

### 命令行参数

也可以通过命令行参数进行配置：

```bash
./pod-manager --cpu-ratio 1.5 --mem-ratio 1.5 --namespaces default,test
```

## 常见问题

### 证书问题

Pod Manager会自动生成TLS证书，如果遇到证书相关问题，可以检查Pod日志：

```bash
kubectl logs -l app=pod-manager
```

### 资源调整不生效

确认webhook已正确注册并且目标命名空间在配置范围内：

```bash
# 检查webhook配置
kubectl get mutatingwebhookconfigurations
```