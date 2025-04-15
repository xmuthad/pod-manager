package cert

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// CertConfig 存储证书配置
type CertConfig struct {
	CertDir     string
	ServiceName string
	Namespace   string
}

// Generator 证书生成器
type Generator struct {
	config CertConfig
}

// NewGenerator 创建证书生成器实例
func NewGenerator(config CertConfig) *Generator {
	return &Generator{config: config}
}

// Generate 生成证书和私钥
func (g *Generator) Generate() error {
	// 创建证书目录
	if err := os.MkdirAll(g.config.CertDir, 0755); err != nil {
		return fmt.Errorf("创建证书目录失败: %v", err)
	}

	// 生成私钥
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return fmt.Errorf("生成私钥失败: %v", err)
	}

	// 创建证书模板
	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			Organization: []string{"pod-manager"},
			CommonName:   fmt.Sprintf("%s.%s.svc", g.config.ServiceName, g.config.Namespace),
		},
		DNSNames: []string{
			g.config.ServiceName,
			fmt.Sprintf("%s.%s", g.config.ServiceName, g.config.Namespace),
			fmt.Sprintf("%s.%s.svc", g.config.ServiceName, g.config.Namespace),
		},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1")},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}

	// 自签名证书
	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return fmt.Errorf("生成证书失败: %v", err)
	}

	// 编码证书
	certBuffer := &bytes.Buffer{}
	if err := pem.Encode(certBuffer, &pem.Block{Type: "CERTIFICATE", Bytes: derBytes}); err != nil {
		return fmt.Errorf("编码证书失败: %v", err)
	}

	// 编码私钥
	keyBuffer := &bytes.Buffer{}
	privateKeyBytes := x509.MarshalPKCS1PrivateKey(privateKey)
	if err := pem.Encode(keyBuffer, &pem.Block{Type: "RSA PRIVATE KEY", Bytes: privateKeyBytes}); err != nil {
		return fmt.Errorf("编码私钥失败: %v", err)
	}

	// 保存证书和私钥
	certPath := filepath.Join(g.config.CertDir, "tls.crt")
	keyPath := filepath.Join(g.config.CertDir, "tls.key")

	if err := os.WriteFile(certPath, certBuffer.Bytes(), 0644); err != nil {
		return fmt.Errorf("保存证书失败: %v", err)
	}

	if err := os.WriteFile(keyPath, keyBuffer.Bytes(), 0600); err != nil {
		return fmt.Errorf("保存私钥失败: %v", err)
	}

	return nil
}
