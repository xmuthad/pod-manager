package admission

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"

	admission_v1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"

	"github.com/holgerhou/pod-manager/pkg/config"
)

// Handler 处理准入请求
type Handler struct {
	config *config.Config
}

// NewHandler 创建Handler实例
func NewHandler(config *config.Config) *Handler {
	return &Handler{config: config}
}

// parseAdmissionRequest 解析准入请求
func (h *Handler) parseAdmissionRequest(r *http.Request) (*admission_v1.AdmissionReview, *corev1.Pod, error) {
	var admissionReview admission_v1.AdmissionReview
	if err := json.NewDecoder(r.Body).Decode(&admissionReview); err != nil {
		return nil, nil, fmt.Errorf("解码错误: %v", err)
	}

	pod := corev1.Pod{}
	if err := json.Unmarshal(admissionReview.Request.Object.Raw, &pod); err != nil {
		return &admissionReview, nil, fmt.Errorf("解析Pod错误: %v", err)
	}
	return &admissionReview, &pod, nil
}

// applyResourceLimits 应用资源限制
func (h *Handler) applyResourceChange(pod *corev1.Pod) ([]byte, error) {
	var patches []map[string]any

	log.Printf("开始处理Pod资源修改: %s/%s", pod.Namespace, pod.Name)

	for i, container := range pod.Spec.Containers {
		if container.Resources.Requests != nil {
			requests := corev1.ResourceList{}
			containerName := container.Name

			if cpu := container.Resources.Requests.Cpu(); cpu != nil && !cpu.IsZero() && h.config.CPUOvercommitRatio > 0 {
				originalCPU := cpu.MilliValue()
				// 计算新的CPU值，并确保至少为100m (0.1核)
				calculatedCPU := int64(float64(originalCPU) / h.config.CPUOvercommitRatio)
				if calculatedCPU < 100 && originalCPU >= 100 {
					calculatedCPU = 100 // 确保至少保留100m (0.1核)
				} else if calculatedCPU == 0 && originalCPU > 0 {
					calculatedCPU = originalCPU / 10 // 如果计算结果为0，至少保留原值的10%
					if calculatedCPU == 0 {
						calculatedCPU = 1 // 确保至少为1m
					}
				}
				newCPU := resource.NewMilliQuantity(
					calculatedCPU,
					cpu.Format,
				)
				requests["cpu"] = *newCPU
				log.Printf("容器 [%s] CPU资源修改: %vm -> %vm (超售比例: %.2f)",
					containerName,
					float64(originalCPU)/1000,
					float64(newCPU.MilliValue())/1000,
					h.config.CPUOvercommitRatio)
			}

			if mem := container.Resources.Requests.Memory(); mem != nil && !mem.IsZero() && h.config.MemoryOvercommitRatio > 0 {
				originalMem := mem.Value()
				// 计算新的内存值，并确保不会过小
				calculatedMem := int64(float64(originalMem) / h.config.MemoryOvercommitRatio)
				// 确保至少保留原始内存的10%
				minMem := originalMem / 10
				// 设置最小绝对值为4Mi (4 * 1024 * 1024)
				minAbsoluteMem := int64(4 * 1024 * 1024)

				if calculatedMem < minMem && originalMem >= minAbsoluteMem {
					calculatedMem = minMem // 确保至少保留原值的10%
				} else if calculatedMem < minAbsoluteMem && originalMem >= minAbsoluteMem {
					calculatedMem = minAbsoluteMem // 确保至少为4Mi
				} else if calculatedMem == 0 && originalMem > 0 {
					// 如果计算结果为0但原始值大于0，至少保留1Mi
					calculatedMem = int64(1 * 1024 * 1024)
				}

				newMem := resource.NewQuantity(
					calculatedMem,
					mem.Format,
				)
				requests["memory"] = *newMem
				log.Printf("容器 [%s] 内存资源修改: %v -> %v (超售比例: %.2f)",
					containerName,
					originalMem,
					newMem.Value(),
					h.config.MemoryOvercommitRatio)
			}

			if len(requests) > 0 {
				patches = append(patches, map[string]interface{}{
					"op":    "add",
					"path":  fmt.Sprintf("/spec/containers/%d/resources/requests", i),
					"value": requests,
				})
			}
		}
	}

	if len(patches) > 0 {
		log.Printf("完成Pod [%s/%s] 资源修改，共修改 %d 个容器", pod.Namespace, pod.Name, len(patches))
	} else {
		log.Printf("Pod [%s/%s] 无需修改资源", pod.Namespace, pod.Name)
	}

	return json.Marshal(patches)
}

// buildAdmissionResponse 构建准入响应
func (h *Handler) buildAdmissionResponse(admissionReview *admission_v1.AdmissionReview, patchBytes []byte) {
	admissionReview.Response = &admission_v1.AdmissionResponse{
		UID:     admissionReview.Request.UID,
		Allowed: true,
		Patch:   patchBytes,
		PatchType: func() *admission_v1.PatchType {
			pt := admission_v1.PatchTypeJSONPatch
			return &pt
		}(),
	}
}

// ServeHTTP 处理HTTP请求
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	log.Printf("收到准入请求: %s %s", r.Method, r.URL.Path)

	admissionReview, pod, err := h.parseAdmissionRequest(r)
	if err != nil {
		log.Printf("解析准入请求失败: %v", err)
		admissionReview.Response = &admission_v1.AdmissionResponse{
			UID:     admissionReview.Request.UID,
			Allowed: true,
		}
		json.NewEncoder(w).Encode(admissionReview)
		return
	}

	log.Printf("成功解析Pod: %s/%s (UID: %s)", pod.Namespace, pod.Name, pod.UID)

	// 检查Pod是否在目标命名空间中
	if len(h.config.TargetNamespaces) > 0 {
		isTargetNamespace := false
		for _, ns := range h.config.TargetNamespaces {
			if pod.Namespace == ns {
				isTargetNamespace = true
				log.Printf("Pod [%s/%s] 在目标命名空间中，将进行资源修改", pod.Namespace, pod.Name)
				break
			}
		}
		if !isTargetNamespace {
			// 不在目标命名空间中，跳过资源修改
			log.Printf("Pod [%s/%s] 不在目标命名空间列表 %v 中，跳过资源修改", pod.Namespace, pod.Name, h.config.TargetNamespaces)
			admissionReview.Response = &admission_v1.AdmissionResponse{
				UID:     admissionReview.Request.UID,
				Allowed: true,
			}
			json.NewEncoder(w).Encode(admissionReview)
			return
		}
	} else {
		log.Printf("未指定目标命名空间，将处理所有命名空间中的Pod")
	}

	patchBytes, err := h.applyResourceChange(pod)
	if err != nil {
		log.Printf("应用资源修改失败: %v", err)
		emptyPatches := []map[string]interface{}{}
		patchBytes, _ = json.Marshal(emptyPatches)
	}

	// 打印最终的patch内容
	log.Printf("Pod [%s/%s] 的最终patch内容: %s", pod.Namespace, pod.Name, string(patchBytes))

	h.buildAdmissionResponse(admissionReview, patchBytes)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(admissionReview)
}
