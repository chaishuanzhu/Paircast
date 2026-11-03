package account

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

const sessionPrefix = "pc1."

var errBadSession = errors.New("invalid token")

type sessionClaims struct {
	UserID  int64 `json:"u"`
	Version int64 `json:"v"`
	Expires int64 `json:"e"` // Unix 秒
}

// sessionSigner 签发与校验会话令牌：pc1.<base64url(claims)>.<base64url(HMAC-SHA256)>。
// 令牌只带账号 ID 与 token_version，账号状态每次请求都从存储读取。
type sessionSigner struct{ secret []byte }

func (s sessionSigner) sign(c sessionClaims) string {
	payload := base64.RawURLEncoding.EncodeToString(mustJSON(c))
	return sessionPrefix + payload + "." + s.mac(payload)
}

func (s sessionSigner) mac(payload string) string {
	m := hmac.New(sha256.New, s.secret)
	m.Write([]byte(payload))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func (s sessionSigner) verify(token string, now time.Time) (sessionClaims, error) {
	var c sessionClaims
	rest, ok := strings.CutPrefix(token, sessionPrefix)
	if !ok {
		return c, errBadSession
	}
	payload, sig, ok := strings.Cut(rest, ".")
	if !ok || !hmac.Equal([]byte(sig), []byte(s.mac(payload))) {
		return c, errBadSession
	}
	raw, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil || json.Unmarshal(raw, &c) != nil || c.UserID <= 0 {
		return c, errBadSession
	}
	if now.Unix() >= c.Expires {
		return c, errors.New("token expired")
	}
	return c, nil
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}
