package main

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"strings"
	"time"

	"github.com/chaishuanzhu/Paircast/server/internal/account"
	"github.com/chaishuanzhu/Paircast/server/internal/config"
)

// Config 是 Paircast 服务的配置（JSON，路径由 CONFIG_PATH 指定，默认 configs/paircast.json）。
// 密钥只建议用环境变量提供：PAIRCAST_SESSION_SECRET、PAIRCAST_IM_SECRET、PAIRCAST_IM_WEBHOOK_SECRET
// （未设置时读 GO-IM 网关的 GOIM_APP_<APP_ID>_SECRET / _WEBHOOK_SECRET）、PAIRCAST_MYSQL_DSN、PAIRCAST_MAIL_PASSWORD、
// PAIRCAST_BLOB_ACCESS_KEY / PAIRCAST_BLOB_SECRET_KEY，以及媒体库的 PAIRCAST_MEDIA_<ID>_* / PAIRCAST_TMDB_ACCESS_TOKEN / PAIRCAST_OPENSUBTITLES_API_KEY。
type Config struct {
	HTTPAddr string `json:"http_addr"` // 默认 ":8090"

	// IM 服务端 API（/server/v1/*）与 webhook。Paircast 在 IM 侧登记为一个接入方，
	// webhook_url 指向本服务的 /im/webhook，订阅 group.member_left 与 group.dismissed。
	IM struct {
		BaseURL       string          `json:"base_url"`   // 服务端 API 地址，例如 "http://gateway:8080"
		PublicURL     string          `json:"public_url"` // 客户端连接 IM 的地址，空 = 与 Paircast 服务同源（同域名反代）
		AppID         string          `json:"app_id"`
		Secret        string          `json:"secret"`
		WebhookSecret string          `json:"webhook_secret"`
		TokenTTL      config.Duration `json:"token_ttl"` // 签发给客户端的 IM 令牌有效期，默认 IM 服务端上限
	} `json:"im"`

	// 账号：会话令牌密钥（≥ 16 字符）、会话有效期（默认 720h）、启动时确保存在的管理员邮箱。
	Account struct {
		SessionSecret string          `json:"session_secret"`
		SessionTTL    config.Duration `json:"session_ttl"`
		AdminEmail    string          `json:"admin_email"`
	} `json:"account"`

	// 发信（管理员建号时把初始密码发到邮箱）；未启用时初始密码写日志 / 显示给管理员。
	Mail account.MailConfig `json:"mail"`

	// MySQL 保存房间与刮削缓存；DSN 为空时都在内存中（重启丢失）。
	MySQL struct {
		DSN string `json:"dsn"`
	} `json:"mysql"`

	Media config.MediaConfig `json:"media"`

	// 共享 / 在线下载的字幕所在的 S3 兼容存储；endpoint 为空时不提供字幕共享与在线字幕下载。
	BlobStore  config.MediaS3Config `json:"blob_store"`
	BlobPrefix string               `json:"blob_prefix"` // 对象键前缀（键本身以 "paircast/subtitles/" 开头），默认为空
}

func loadConfig(path string) (*Config, error) {
	cfg := &Config{HTTPAddr: ":8090", Media: config.DefaultMedia()}
	data, err := os.ReadFile(path)
	switch {
	case os.IsNotExist(err):
		log.Printf("[paircast] no config file at %s, using defaults + env", path)
	case err != nil:
		return nil, err
	default:
		if err := json.Unmarshal(data, cfg); err != nil {
			return nil, err
		}
	}
	envOverride(&cfg.IM.BaseURL, "PAIRCAST_IM_BASE_URL")
	envOverride(&cfg.IM.AppID, "PAIRCAST_IM_APP_ID")
	envOverride(&cfg.IM.Secret, "PAIRCAST_IM_SECRET")
	envOverride(&cfg.IM.WebhookSecret, "PAIRCAST_IM_WEBHOOK_SECRET")
	// 与 GO-IM 网关共用同一份接入方密钥（apps.env / Secret goim-apps）时，直接读网关的变量名。
	if id := appEnvID(cfg.IM.AppID); id != "" {
		envFallback(&cfg.IM.Secret, "GOIM_APP_"+id+"_SECRET")
		envFallback(&cfg.IM.WebhookSecret, "GOIM_APP_"+id+"_WEBHOOK_SECRET")
	}
	envOverride(&cfg.IM.PublicURL, "PAIRCAST_IM_PUBLIC_URL")
	envOverride(&cfg.Account.SessionSecret, "PAIRCAST_SESSION_SECRET")
	envOverride(&cfg.Account.AdminEmail, "PAIRCAST_ADMIN_EMAIL")
	envOverride(&cfg.Mail.Password, "PAIRCAST_MAIL_PASSWORD")
	envOverride(&cfg.MySQL.DSN, "PAIRCAST_MYSQL_DSN")
	envOverride(&cfg.BlobStore.AccessKey, "PAIRCAST_BLOB_ACCESS_KEY")
	envOverride(&cfg.BlobStore.SecretKey, "PAIRCAST_BLOB_SECRET_KEY")
	config.ApplyMediaEnv(&cfg.Media)

	if cfg.IM.BaseURL == "" || cfg.IM.AppID == "" || cfg.IM.Secret == "" {
		return nil, errors.New("im.base_url, im.app_id and im.secret (PAIRCAST_IM_SECRET) are required")
	}
	if len(cfg.Account.SessionSecret) < 16 {
		return nil, errors.New("account.session_secret (PAIRCAST_SESSION_SECRET) is required, at least 16 characters")
	}
	if len(cfg.Media.Sources) == 0 {
		return nil, errors.New("media.sources is empty")
	}
	if time.Duration(cfg.Media.RoomRetention) <= 0 {
		cfg.Media.RoomRetention = config.DefaultMedia().RoomRetention
	}
	return cfg, nil
}

func envFallback(dst *string, key string) {
	if *dst == "" {
		*dst = os.Getenv(key)
	}
}

// appEnvID 与 GO-IM 一致：大写，非字母数字换成 _。
func appEnvID(appID string) string {
	b := []byte(strings.ToUpper(appID))
	for i, c := range b {
		if (c < 'A' || c > 'Z') && (c < '0' || c > '9') {
			b[i] = '_'
		}
	}
	return string(b)
}

func envOverride(dst *string, key string) {
	if v := os.Getenv(key); v != "" {
		*dst = v
	}
}
