// Package config 定义媒体库配置。访问密钥只存在服务端，客户端只拿到预签名播放直链。
package config

import (
	"encoding/json"
	"os"
	"strings"
	"time"
)

// Duration 是可序列化为人类可读字符串（例如 "30s"）的 time.Duration。
type Duration time.Duration

// MarshalJSON 实现 json.Marshaler。
func (d Duration) MarshalJSON() ([]byte, error) {
	return json.Marshal(time.Duration(d).String())
}

// UnmarshalJSON 实现 json.Unmarshaler。
func (d *Duration) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	dur, err := time.ParseDuration(s)
	if err != nil {
		return err
	}
	*d = Duration(dur)
	return nil
}

// MediaConfig 保存媒体库设置。
type MediaConfig struct {
	Sources       []MediaSourceConfig `json:"sources"`
	DefaultSource string              `json:"default_source"` // 空 = 第一个源；无前缀的影片 ID 按此源解析
	PlayURLTTL    Duration            `json:"play_url_ttl"`   // 播放直链有效期，默认 "6h"
	ListCacheTTL  Duration            `json:"list_cache_ttl"` // 影片列表缓存，默认 "60s"

	// 刮削与在线字幕。可由环境变量 PAIRCAST_TMDB_ACCESS_TOKEN / PAIRCAST_OPENSUBTITLES_API_KEY 覆盖。
	TMDBAccessToken     string   `json:"tmdb_access_token"`
	TMDBLanguage        string   `json:"tmdb_language"` // 默认 "zh-CN"
	OpenSubtitlesAPIKey string   `json:"opensubtitles_api_key"`
	MetadataTTL         Duration `json:"metadata_ttl"` // 刮削结果缓存，默认 "168h"

	// 贴纸目录所在的源与路径前缀（catalog.json / {pack}/pack.json / 图片）。空 = 默认源的 "stickers/"。
	StickersSource string `json:"stickers_source"`
	StickersPrefix string `json:"stickers_prefix"`

	// 房间：超过该时长未更新的房间由清理任务删除，默认 "72h"。
	RoomRetention Duration `json:"room_retention"`
}

// MediaSourceConfig 描述一个视频源。Type 目前仅支持 "s3"（阿里云 OSS / 七牛 / COS / MinIO 等 S3 兼容存储）；
// 后续扩展 "openlist" / "emby" / "jellyfin"。
type MediaSourceConfig struct {
	ID   string        `json:"id"` // 稳定标识，出现在影片 ID 中（"<id>:<key>"），不要随意修改
	Name string        `json:"name"`
	Type string        `json:"type"`
	S3   MediaS3Config `json:"s3"`
}

// MediaS3Config 为 S3 兼容存储设置。密钥可由环境变量 PAIRCAST_MEDIA_<ID>_ACCESS_KEY / _SECRET_KEY 覆盖（ID 大写）。
type MediaS3Config struct {
	Endpoint  string `json:"endpoint"` // host[:port]，不含协议
	Bucket    string `json:"bucket"`
	Region    string `json:"region"`
	Prefix    string `json:"prefix"` // 只列出该前缀下的影片，例如 "films/"
	AccessKey string `json:"access_key"`
	SecretKey string `json:"secret_key"`
	UseSSL    bool   `json:"use_ssl"`
	PathStyle bool   `json:"path_style"`
}

// DefaultMedia 返回媒体库默认设置。
func DefaultMedia() MediaConfig {
	return MediaConfig{
		PlayURLTTL:    Duration(6 * time.Hour),
		ListCacheTTL:  Duration(60 * time.Second),
		TMDBLanguage:  "zh-CN",
		MetadataTTL:   Duration(7 * 24 * time.Hour),
		RoomRetention: Duration(72 * time.Hour),
	}
}

// ApplyMediaEnv 用环境变量覆盖媒体库密钥，避免写进配置文件。
func ApplyMediaEnv(m *MediaConfig) {
	if v := os.Getenv("PAIRCAST_TMDB_ACCESS_TOKEN"); v != "" {
		m.TMDBAccessToken = v
	}
	if v := os.Getenv("PAIRCAST_OPENSUBTITLES_API_KEY"); v != "" {
		m.OpenSubtitlesAPIKey = v
	}
	for i := range m.Sources {
		id := envID(m.Sources[i].ID)
		if v := os.Getenv("PAIRCAST_MEDIA_" + id + "_ACCESS_KEY"); v != "" {
			m.Sources[i].S3.AccessKey = v
		}
		if v := os.Getenv("PAIRCAST_MEDIA_" + id + "_SECRET_KEY"); v != "" {
			m.Sources[i].S3.SecretKey = v
		}
	}
}

// envID 把 ID 转成环境变量名片段：大写，非字母数字换成 _。
func envID(id string) string {
	return strings.ToUpper(strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' {
			return r
		}
		return '_'
	}, id))
}
