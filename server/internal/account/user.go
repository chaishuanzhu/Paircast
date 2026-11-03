// Package account 是 Paircast 自己的账号体系：邮箱 + 密码登录、会话令牌、管理员后台。
// 每个账号在 IM 侧有一个镜像用户（服务端 API users/import，external_id = 账号 ID），
// 对客户端暴露的用户 ID 一律是 IM uid，房间、信令、举报都按它工作。
package account

import (
	"context"
	"errors"
	"net/mail"
	"strings"
	"unicode"
	"unicode/utf8"
)

// 角色。
const (
	RoleUser  = "user"
	RoleAdmin = "admin"
)

const (
	maxNicknameLen = 32
	minPasswordLen = 6
	maxPasswordLen = 72 // bcrypt 只用前 72 字节
)

var (
	// ErrNotFound 表示账号不存在。
	ErrNotFound = errors.New("user not found")
	// ErrEmailTaken 表示邮箱已被注册。
	ErrEmailTaken = errors.New("email already registered")
)

// User 是一个 Paircast 账号。
type User struct {
	ID                 int64
	Email              string
	PasswordHash       string
	Nickname           string
	AvatarFileID       int64 // IM 文件 ID，经 IM 的 /avatar/{id} 公开访问
	Role               string
	Disabled           bool
	MustChangePassword bool
	TokenVersion       int64 // 改密、禁用时递增，使已签发的会话失效
	IMUID              string
	CreatedAt          int64 // 毫秒
	UpdatedAt          int64
}

// IsAdmin 报告账号是否为管理员。
func (u *User) IsAdmin() bool { return u.Role == RoleAdmin }

func (u *User) clone() *User {
	c := *u
	return &c
}

// Store 持久化账号。
type Store interface {
	// Create 写入新账号并回填 ID；邮箱已存在返回 ErrEmailTaken。
	Create(ctx context.Context, u *User) error
	Get(ctx context.Context, id int64) (*User, error)
	GetByEmail(ctx context.Context, email string) (*User, error)
	GetByIMUID(ctx context.Context, imUID string) (*User, error)
	// List 按创建时间倒序分页，返回总数。
	List(ctx context.Context, offset, limit int) ([]*User, int, error)
	// Update 在锁内读出账号交给 fn 修改后写回；fn 返回错误则不写。
	Update(ctx context.Context, id int64, fn func(*User) error) (*User, error)
	Delete(ctx context.Context, id int64) error
}

// NormalizeEmail 校验并小写化邮箱。
func NormalizeEmail(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" || len(raw) > 254 {
		return "", false
	}
	addr, err := mail.ParseAddress(raw)
	if err != nil || addr.Address != raw || addr.Name != "" {
		return "", false
	}
	at := strings.LastIndexByte(raw, '@')
	if at <= 0 || !strings.Contains(raw[at+1:], ".") {
		return "", false
	}
	return strings.ToLower(raw), true
}

// checkNickname 返回不合法的原因，合法时为空。
func checkNickname(n string) string {
	if n == "" {
		return "nickname required"
	}
	if utf8.RuneCountInString(n) > maxNicknameLen {
		return "nickname too long"
	}
	for _, r := range n {
		if unicode.IsControl(r) {
			return "nickname contains invalid characters"
		}
	}
	return ""
}

func checkPassword(p string) string {
	if len(p) < minPasswordLen {
		return "new password must be at least 6 characters"
	}
	if len(p) > maxPasswordLen {
		return "new password too long"
	}
	return ""
}

func defaultNickname(email string) string {
	name := email
	if at := strings.IndexByte(email, '@'); at > 0 {
		name = email[:at]
	}
	if utf8.RuneCountInString(name) > maxNicknameLen {
		name = string([]rune(name)[:maxNicknameLen])
	}
	return name
}

func maskEmail(email string) string {
	at := strings.IndexByte(email, '@')
	if at <= 0 {
		return "***"
	}
	return email[:1] + "***" + email[at:]
}
