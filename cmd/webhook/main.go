package main

import (
	"flag"
	"log"
	"net/http"
	"strings"

	"github.com/holgerhou/pod-manager/pkg/admission"
	"github.com/holgerhou/pod-manager/pkg/cert"
	"github.com/holgerhou/pod-manager/pkg/config"
	"github.com/holgerhou/pod-manager/pkg/register"
)

func main() {
	// 加载默认配置
	cfg := config.DefaultConfig()

	// 解析命令行参数
	// 将目标命名空间列表转换为逗号分隔的字符串
	targetNamespacesStr := strings.Join(cfg.TargetNamespaces, ",")

	flag.Float64Var(&cfg.CPUOvercommitRatio, "cpu-ratio", cfg.CPUOvercommitRatio, "CPU超售比例")
	flag.Float64Var(&cfg.MemoryOvercommitRatio, "mem-ratio", cfg.MemoryOvercommitRatio, "内存超售比例")
	flag.StringVar(&cfg.Port, "port", cfg.Port, "监听端口")
	flag.StringVar(&cfg.CertDir, "cert-dir", cfg.CertDir, "证书目录")
	flag.StringVar(&cfg.ServiceName, "service-name", cfg.ServiceName, "服务名称")
	flag.StringVar(&targetNamespacesStr, "target-namespaces", targetNamespacesStr, "目标命名空间列表，多个命名空间用逗号分隔，为空则处理所有命名空间")
	flag.Parse()

	// 如果命令行参数指定了目标命名空间，则更新配置
	if targetNamespacesStr != "" {
		cfg.TargetNamespaces = strings.Split(targetNamespacesStr, ",")
	}

	// 生成TLS证书
	certGen := cert.NewGenerator(cert.CertConfig{
		CertDir:     cfg.CertDir,
		ServiceName: cfg.ServiceName,
		Namespace:   cfg.Namespace,
	})

	if err := certGen.Generate(); err != nil {
		log.Fatalf("生成证书失败: %v", err)
	}

	// 注册MutatingWebhook
	registrar, err := register.NewWebhookRegistrar(cfg)
	if err != nil {
		log.Printf("创建Webhook注册器失败: %v，将继续启动服务", err)
	} else {
		if err := registrar.Register(); err != nil {
			log.Printf("注册MutatingWebhook失败: %v，将继续启动服务", err)
		} else {
			log.Printf("成功通过代码注册MutatingWebhook")
		}
	}

	// 创建准入控制器处理器
	handler := admission.NewHandler(cfg)

	// 配置HTTP路由
	http.Handle("/mutate", handler)

	// 启动服务器
	log.Printf("启动服务，CPU超售比例: %.2f, 内存超售比例: %.2f", cfg.CPUOvercommitRatio, cfg.MemoryOvercommitRatio)
	log.Fatal(http.ListenAndServeTLS(
		":"+cfg.Port,
		cfg.CertDir+"/tls.crt",
		cfg.CertDir+"/tls.key",
		nil,
	))
}
