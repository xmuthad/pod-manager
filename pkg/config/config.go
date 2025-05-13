package config

import (
	"log"
	"os"
	"strconv"
	"strings"
)

// Config 存储全局配置
type Config struct {
	// 资源配置
	CPUOvercommitRatio    float64
	MemoryOvercommitRatio float64

	// 服务配置
	Port string

	// 证书配置
	CertDir     string
	ServiceName string
	Namespace   string

	// 目标命名空间配置
	TargetNamespaces []string // 需要进行资源修改的命名空间列表，为空则表示处理所有命名空间
}

// DefaultConfig 返回默认配置
func DefaultConfig() *Config {
	// 设置默认命名空间
	namespace := "default"

	// 直接使用环境变量获取命名空间，这是Kubernetes推荐的方式
	if ns := os.Getenv("POD_NAMESPACE"); ns != "" {
		namespace = ns
		log.Printf("从环境变量获取命名空间: %s", namespace)
	} else {
		log.Printf("环境变量POD_NAMESPACE未设置，使用默认命名空间: %s", namespace)
	}

	// 从环境变量获取CPU超售比例
	cpuRatio := 1.5
	if ratio := os.Getenv("CPU_OVERCOMMIT_RATIO"); ratio != "" {
		if val, err := strconv.ParseFloat(ratio, 64); err == nil {
			cpuRatio = val
			log.Printf("从环境变量获取CPU超售比例: %f", cpuRatio)
		} else {
			log.Printf("解析CPU_OVERCOMMIT_RATIO环境变量失败: %v，使用默认值: %f", err, cpuRatio)
		}
	}

	// 从环境变量获取内存超售比例
	memRatio := 1.5
	if ratio := os.Getenv("MEMORY_OVERCOMMIT_RATIO"); ratio != "" {
		if val, err := strconv.ParseFloat(ratio, 64); err == nil {
			memRatio = val
			log.Printf("从环境变量获取内存超售比例: %f", memRatio)
		} else {
			log.Printf("解析MEMORY_OVERCOMMIT_RATIO环境变量失败: %v，使用默认值: %f", err, memRatio)
		}
	}

	// 从环境变量获取目标命名空间列表
	targetNamespaces := []string{}
	if namespaces := os.Getenv("TARGET_NAMESPACES"); namespaces != "" {
		targetNamespaces = strings.Split(namespaces, ",")
	}

	return &Config{
		CPUOvercommitRatio:    cpuRatio,
		MemoryOvercommitRatio: memRatio,
		Port:                  "8443",
		CertDir:               "/etc/webhook/certs",
		ServiceName:           "pod-manager",
		Namespace:             namespace,
		TargetNamespaces:      targetNamespaces, // 从环境变量获取，为空则表示处理所有命名空间
	}
}
