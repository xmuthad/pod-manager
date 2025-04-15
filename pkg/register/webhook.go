package register

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"

	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"

	"github.com/holgerhou/pod-manager/pkg/config"
)

// WebhookRegistrar 负责注册MutatingWebhook
type WebhookRegistrar struct {
	clientset *kubernetes.Clientset
	config    *config.Config
}

// NewWebhookRegistrar 创建WebhookRegistrar实例
func NewWebhookRegistrar(config *config.Config) (*WebhookRegistrar, error) {
	// 创建in-cluster配置
	restConfig, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("获取集群内配置失败: %v", err)
	}

	// 创建clientset
	clientset, err := kubernetes.NewForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("创建Kubernetes客户端失败: %v", err)
	}

	return &WebhookRegistrar{
		clientset: clientset,
		config:    config,
	}, nil
}

// Register 注册MutatingWebhook
func (wr *WebhookRegistrar) Register() error {
	// 读取CA证书
	caBundle, err := os.ReadFile(filepath.Join(wr.config.CertDir, "tls.crt"))
	if err != nil {
		return fmt.Errorf("读取CA证书失败: %v", err)
	}

	log.Printf("成功读取CA证书，长度: %d 字节", len(caBundle))
	if len(caBundle) == 0 {
		return fmt.Errorf("CA证书内容为空")
	}

	// 创建MutatingWebhookConfiguration
	webhookConfig := &admissionregistrationv1.MutatingWebhookConfiguration{
		ObjectMeta: metav1.ObjectMeta{
			Name: "pod-mutating-webhook",
		},
		Webhooks: []admissionregistrationv1.MutatingWebhook{
			{
				Name:                    "pod-mutator.example.com",
				AdmissionReviewVersions: []string{"v1"},
				SideEffects: func() *admissionregistrationv1.SideEffectClass {
					se := admissionregistrationv1.SideEffectClassNone
					return &se
				}(),
				Rules: []admissionregistrationv1.RuleWithOperations{
					{
						Operations: []admissionregistrationv1.OperationType{
							admissionregistrationv1.Create,
						},
						Rule: admissionregistrationv1.Rule{
							APIGroups:   []string{"*"},
							APIVersions: []string{"v1"},
							Resources:   []string{"pods"},
						},
					},
				},
				ClientConfig: admissionregistrationv1.WebhookClientConfig{
					Service: &admissionregistrationv1.ServiceReference{
						Namespace: wr.config.Namespace,
						Name:      wr.config.ServiceName,
						Path:      func() *string { p := "/mutate"; return &p }(),
					},
					CABundle: caBundle,
				},
				FailurePolicy: func() *admissionregistrationv1.FailurePolicyType {
					fp := admissionregistrationv1.Ignore
					return &fp
				}(),
				// 移除命名空间选择器，使webhook默认处理所有命名空间的Pod
				// 空的选择器会匹配所有命名空间
				NamespaceSelector: &metav1.LabelSelector{},
			},
		},
	}

	log.Printf("准备注册MutatingWebhook，配置详情：")
	log.Printf("- Webhook名称: %s", webhookConfig.Webhooks[0].Name)
	log.Printf("- 目标资源: %v", webhookConfig.Webhooks[0].Rules[0].Resources)
	log.Printf("- 操作类型: %v", webhookConfig.Webhooks[0].Rules[0].Operations)

	// 安全地打印服务配置，避免空指针异常
	if webhookConfig.Webhooks[0].ClientConfig.Service != nil {
		if webhookConfig.Webhooks[0].ClientConfig.Service.Name != "" {
			log.Printf("- 服务名称: %s", webhookConfig.Webhooks[0].ClientConfig.Service.Name)
		} else {
			log.Printf("- 服务名称: <nil>")
		}
		log.Printf("- 服务命名空间: %s", webhookConfig.Webhooks[0].ClientConfig.Service.Namespace)
		if webhookConfig.Webhooks[0].ClientConfig.Service.Path != nil {
			log.Printf("- 服务路径: %s", *webhookConfig.Webhooks[0].ClientConfig.Service.Path)
		} else {
			log.Printf("- 服务路径: <nil>")
		}
	} else {
		log.Printf("- 服务配置: <nil>")
	}

	// 安全地打印失败策略
	if webhookConfig.Webhooks[0].FailurePolicy != nil {
		log.Printf("- 失败策略: %s", string(*webhookConfig.Webhooks[0].FailurePolicy))
	} else {
		log.Printf("- 失败策略: <nil>")
	}

	// 打印命名空间选择器配置
	log.Printf("- 命名空间选择器: %v (空选择器将匹配所有命名空间)", webhookConfig.Webhooks[0].NamespaceSelector)
	// 打印目标命名空间配置
	if len(wr.config.TargetNamespaces) > 0 {
		log.Printf("- 目标命名空间: %v (仅这些命名空间中的Pod会被处理)", wr.config.TargetNamespaces)
	} else {
		log.Printf("- 目标命名空间: 未指定 (所有命名空间中的Pod都会被处理)")
	}

	// 检查是否已存在
	existing, err := wr.clientset.AdmissionregistrationV1().MutatingWebhookConfigurations().Get(
		context.TODO(), webhookConfig.Name, metav1.GetOptions{},
	)

	if err == nil {
		// 已存在，更新
		log.Printf("更新MutatingWebhookConfiguration: %s", webhookConfig.Name)
		webhookConfig.ResourceVersion = existing.ResourceVersion
		_, err = wr.clientset.AdmissionregistrationV1().MutatingWebhookConfigurations().Update(
			context.TODO(), webhookConfig, metav1.UpdateOptions{},
		)
		return err
	} else {
		// 不存在，创建
		log.Printf("创建MutatingWebhookConfiguration: %s", webhookConfig.Name)
		_, err = wr.clientset.AdmissionregistrationV1().MutatingWebhookConfigurations().Create(
			context.TODO(), webhookConfig, metav1.CreateOptions{},
		)
		return err
	}
}
