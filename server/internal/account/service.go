package account

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"

	"github.com/chaishuanzhu/GO-IM/pkg/imserver"
)

// IM 是账号体系用到的 IM 服务端 API（*imserver.Client 实现）。
type IM interface {
	ImportUser(ctx context.Context, u imserver.ImportUser) (*imserver.User, error)
	IssueToken(ctx context.Context, user imserver.UserRef, ttl time.Duration) (*imserver.Token, error)
	SetUserDisabled(ctx context.Context, user imserver.UserRef, disabled bool) error
	DeleteUser(ctx context.Context, user imserver.UserRef) error
	ListReports(ctx context.Context, status string, offset, limit int) (*imserver.ReportList, error)
	GetReport(ctx context.Context, id int64) (*imserver.Report, error)
	ResolveReport(ctx context.Context, id int64, action, handledBy string) (string, error)
}

// Error 是带 HTTP 状态码的业务错误，消息直接作为响应正文（客户端按正文区分原因）。
type Error struct {
	Status  int
	Message string
}

func (e *Error) Error() string { return e.Message }

func fail(status int, msg string) error { return &Error{status, msg} }

var errIMUnavailable = fail(http.StatusBadGateway, "im unavailable")

// Options 配置 Service。
type Options struct {
	SessionSecret string        // 必填，会话令牌的 HMAC 密钥
	SessionTTL    time.Duration // 默认 30 天
	IMTokenTTL    time.Duration // 0 = IM 服务端上限
}

// Service 实现账号业务。
type Service struct {
	store  Store
	im     IM
	mailer Mailer // nil = 不发信，初始密码写日志 / 返回给管理员
	signer sessionSigner
	opts   Options
	now    func() time.Time
}

// NewService 创建账号服务。
func NewService(store Store, im IM, mailer Mailer, opts Options) (*Service, error) {
	if len(opts.SessionSecret) < 16 {
		return nil, errors.New("session secret must be at least 16 characters")
	}
	if opts.SessionTTL <= 0 {
		opts.SessionTTL = 30 * 24 * time.Hour
	}
	return &Service{store: store, im: im, mailer: mailer, signer: sessionSigner{[]byte(opts.SessionSecret)}, opts: opts, now: time.Now}, nil
}

// MailEnabled 报告是否配置了发信。
func (s *Service) MailEnabled() bool { return s.mailer != nil }

// Session 为账号签发会话令牌。
func (s *Service) Session(u *User) string {
	return s.signer.sign(sessionClaims{UserID: u.ID, Version: u.TokenVersion, Expires: s.now().Add(s.opts.SessionTTL).Unix()})
}

// Verify 校验会话令牌并返回当前账号；令牌无效、账号已删除 / 禁用、版本过期都返回 401 错误。
func (s *Service) Verify(ctx context.Context, token string) (*User, error) {
	c, err := s.signer.verify(token, s.now())
	if err != nil {
		return nil, fail(http.StatusUnauthorized, err.Error())
	}
	u, err := s.store.Get(ctx, c.UserID)
	if errors.Is(err, ErrNotFound) {
		return nil, fail(http.StatusUnauthorized, "account deleted")
	}
	if err != nil {
		return nil, err
	}
	if u.Disabled {
		return nil, fail(http.StatusUnauthorized, "account disabled")
	}
	if u.TokenVersion != c.Version {
		return nil, fail(http.StatusUnauthorized, "token revoked")
	}
	return u, nil
}

// Login 用邮箱（或 IM uid）+ 密码登录。
func (s *Service) Login(ctx context.Context, account, password string) (*User, error) {
	account = strings.TrimSpace(account)
	if account == "" {
		return nil, fail(http.StatusBadRequest, "account required")
	}
	if password == "" {
		return nil, fail(http.StatusUnauthorized, "password required")
	}
	var u *User
	var err error
	if strings.Contains(account, "@") {
		u, err = s.store.GetByEmail(ctx, strings.ToLower(account))
	} else {
		u, err = s.store.GetByIMUID(ctx, account)
	}
	if errors.Is(err, ErrNotFound) {
		return nil, fail(http.StatusUnauthorized, "invalid account or password")
	}
	if err != nil {
		return nil, err
	}
	if bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(password)) != nil {
		return nil, fail(http.StatusUnauthorized, "invalid account or password")
	}
	if u.Disabled {
		return nil, fail(http.StatusForbidden, "account disabled")
	}
	return s.ensureIM(ctx, u)
}

// IMToken 为账号签发 IM 令牌。
func (s *Service) IMToken(ctx context.Context, u *User) (*imserver.Token, error) {
	u, err := s.ensureIM(ctx, u)
	if err != nil {
		return nil, err
	}
	t, err := s.im.IssueToken(ctx, imserver.UID(u.IMUID), s.opts.IMTokenTTL)
	if err != nil {
		log.Printf("[account] issue im token for %d: %v", u.ID, err)
		return nil, errIMUnavailable
	}
	return t, nil
}

// ensureIM 确保账号在 IM 侧有镜像用户（建号时 IM 不可用会留下没有 im_uid 的账号）。
func (s *Service) ensureIM(ctx context.Context, u *User) (*User, error) {
	if u.IMUID != "" {
		return u, nil
	}
	imu, err := s.im.ImportUser(ctx, imserver.ImportUser{ExternalID: externalID(u.ID), Nickname: imserver.String(u.Nickname)})
	if err != nil {
		log.Printf("[account] import user %d into im: %v", u.ID, err)
		return nil, errIMUnavailable
	}
	return s.store.Update(ctx, u.ID, func(x *User) error {
		x.IMUID = imu.UID
		x.UpdatedAt = s.now().UnixMilli()
		return nil
	})
}

func externalID(id int64) string { return strconv.FormatInt(id, 10) }

// ChangePassword 修改密码并清除“须改密”标记；其他设备上的会话随之失效，返回更新后的账号（用它重签会话）。
func (s *Service) ChangePassword(ctx context.Context, u *User, oldPassword, newPassword string) (*User, error) {
	if oldPassword == "" || newPassword == "" {
		return nil, fail(http.StatusBadRequest, "old_password and new_password required")
	}
	if msg := checkPassword(newPassword); msg != "" {
		return nil, fail(http.StatusBadRequest, msg)
	}
	if bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(oldPassword)) != nil {
		return nil, fail(http.StatusUnauthorized, "invalid current password")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(newPassword), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}
	return s.store.Update(ctx, u.ID, func(x *User) error {
		x.PasswordHash = string(hash)
		x.MustChangePassword = false
		x.TokenVersion++
		x.UpdatedAt = s.now().UnixMilli()
		return nil
	})
}

// UpdateProfile 修改昵称和 / 或头像（IM 文件 ID，0 清除），并同步到 IM。
func (s *Service) UpdateProfile(ctx context.Context, u *User, nickname *string, avatarFileID *int64) (*User, error) {
	if nickname == nil && avatarFileID == nil {
		return nil, fail(http.StatusBadRequest, "nothing to update")
	}
	if nickname != nil {
		if msg := checkNickname(*nickname); msg != "" {
			return nil, fail(http.StatusBadRequest, msg)
		}
	}
	if avatarFileID != nil && *avatarFileID < 0 {
		return nil, fail(http.StatusBadRequest, "invalid avatar_file_id")
	}
	u, err := s.ensureIM(ctx, u)
	if err != nil {
		return nil, err
	}
	// IM 校验头像文件属于该用户；先同步 IM，失败时不改本地。
	_, err = s.im.ImportUser(ctx, imserver.ImportUser{ExternalID: externalID(u.ID), Nickname: nickname, AvatarFileID: avatarFileID})
	var apiErr *imserver.APIError
	if errors.As(err, &apiErr) && apiErr.Status == http.StatusBadRequest {
		return nil, fail(http.StatusBadRequest, apiErr.Message)
	}
	if err != nil {
		log.Printf("[account] sync profile %d to im: %v", u.ID, err)
		return nil, errIMUnavailable
	}
	return s.store.Update(ctx, u.ID, func(x *User) error {
		if nickname != nil {
			x.Nickname = *nickname
		}
		if avatarFileID != nil {
			x.AvatarFileID = *avatarFileID
		}
		x.UpdatedAt = s.now().UnixMilli()
		return nil
	})
}

// DeleteSelf 注销自己的账号（管理员不能自助注销）。
func (s *Service) DeleteSelf(ctx context.Context, u *User, password string) error {
	if bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(password)) != nil {
		return fail(http.StatusUnauthorized, "invalid password")
	}
	if u.IsAdmin() {
		return fail(http.StatusForbidden, "admin accounts cannot be deleted here")
	}
	return s.delete(ctx, u)
}

func (s *Service) delete(ctx context.Context, u *User) error {
	if u.IMUID != "" {
		if err := s.im.DeleteUser(ctx, imserver.UID(u.IMUID)); err != nil && !imserver.IsNotFound(err) {
			log.Printf("[account] delete im user %s: %v", u.IMUID, err)
			return errIMUnavailable
		}
	}
	return s.store.Delete(ctx, u.ID)
}

// Created 是管理员建号的结果。Mailed 为 false 时 InitialPassword 需要管理员转交。
type Created struct {
	User            *User
	Mailed          bool
	InitialPassword string
}

// CreateUser 以随机初始密码建号（首次登录须改密），并尽量把密码发到邮箱。
func (s *Service) CreateUser(ctx context.Context, rawEmail, nickname, role string) (*Created, error) {
	email, ok := NormalizeEmail(rawEmail)
	if !ok {
		return nil, fail(http.StatusBadRequest, "invalid email")
	}
	nickname = strings.TrimSpace(nickname)
	if nickname == "" {
		nickname = defaultNickname(email)
	} else if msg := checkNickname(nickname); msg != "" {
		return nil, fail(http.StatusBadRequest, msg)
	}
	password, err := randomPassword(initialPasswordLen)
	if err != nil {
		return nil, err
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}
	now := s.now().UnixMilli()
	u := &User{Email: email, PasswordHash: string(hash), Nickname: nickname, Role: role, MustChangePassword: true, CreatedAt: now, UpdatedAt: now}
	if err := s.store.Create(ctx, u); err != nil {
		if errors.Is(err, ErrEmailTaken) {
			return nil, fail(http.StatusConflict, "email already registered")
		}
		return nil, err
	}
	if u, err = s.ensureIM(ctx, u); err != nil {
		return nil, err
	}
	out := &Created{User: u, InitialPassword: password}
	if s.mailer != nil {
		subject, text, body := initialPasswordMail(email, password, role == RoleAdmin)
		sendCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
		err := s.mailer.Send(sendCtx, email, subject, text, body)
		cancel()
		if err == nil {
			out.Mailed = true
			out.InitialPassword = ""
		} else {
			log.Printf("[account] WARNING: sending initial password to %s failed: %v", maskEmail(email), err)
		}
	}
	return out, nil
}

// BootstrapAdmin 确保 email 对应的账号存在且为管理员：不存在时以随机密码创建并发信（无法发信时写日志），
// 已存在时只提升角色。多副本同时启动时只有抢到插入的那个会建号。
func (s *Service) BootstrapAdmin(ctx context.Context, rawEmail string) error {
	email, ok := NormalizeEmail(rawEmail)
	if !ok {
		return fmt.Errorf("invalid admin_email %q", rawEmail)
	}
	existing, err := s.store.GetByEmail(ctx, email)
	switch {
	case err == nil:
		if existing.IsAdmin() {
			return nil
		}
		_, err = s.store.Update(ctx, existing.ID, func(x *User) error {
			x.Role = RoleAdmin
			x.UpdatedAt = s.now().UnixMilli()
			return nil
		})
		if err == nil {
			log.Printf("[account] existing account %s promoted to admin", maskEmail(email))
		}
		return err
	case !errors.Is(err, ErrNotFound):
		return err
	}
	c, err := s.CreateUser(ctx, email, "", RoleAdmin)
	var e *Error
	if errors.As(err, &e) && e.Status == http.StatusConflict {
		return nil
	}
	if err != nil {
		return fmt.Errorf("create admin: %w", err)
	}
	log.Printf("[account] created admin account %s (im uid %s)", maskEmail(email), c.User.IMUID)
	if !c.Mailed {
		log.Printf("[account] WARNING: initial password for %s could not be emailed: %s — log in and change it now", email, c.InitialPassword)
	}
	return nil
}

// Users 分页列出账号。
func (s *Service) Users(ctx context.Context, offset, limit int) ([]*User, int, error) {
	return s.store.List(ctx, offset, limit)
}

func (s *Service) target(ctx context.Context, imUID string) (*User, error) {
	if imUID == "" {
		return nil, fail(http.StatusBadRequest, "target_uid required")
	}
	u, err := s.store.GetByIMUID(ctx, imUID)
	if errors.Is(err, ErrNotFound) {
		return nil, fail(http.StatusNotFound, "user not found")
	}
	return u, err
}

// SetDisabled 由管理员禁用 / 启用账号；禁用会让会话失效并禁用 IM 账号（立即下线）。
func (s *Service) SetDisabled(ctx context.Context, actor *User, targetUID string, disabled bool) error {
	t, err := s.target(ctx, targetUID)
	if err != nil {
		return err
	}
	if disabled && t.ID == actor.ID {
		return fail(http.StatusBadRequest, "cannot disable yourself")
	}
	if err := s.im.SetUserDisabled(ctx, imserver.UID(t.IMUID), disabled); err != nil {
		log.Printf("[account] set im user %s disabled=%v: %v", t.IMUID, disabled, err)
		return errIMUnavailable
	}
	return s.markDisabled(ctx, t.ID, disabled)
}

func (s *Service) markDisabled(ctx context.Context, id int64, disabled bool) error {
	_, err := s.store.Update(ctx, id, func(x *User) error {
		if disabled && !x.Disabled {
			x.TokenVersion++
		}
		x.Disabled = disabled
		x.UpdatedAt = s.now().UnixMilli()
		return nil
	})
	return err
}

// DeleteUser 由管理员删除账号（连同 IM 账号）。
func (s *Service) DeleteUser(ctx context.Context, actor *User, targetUID string) error {
	t, err := s.target(ctx, targetUID)
	if err != nil {
		return err
	}
	if t.ID == actor.ID {
		return fail(http.StatusBadRequest, "cannot delete yourself")
	}
	return s.delete(ctx, t)
}

// Reports 分页列出 IM 里的举报。
func (s *Service) Reports(ctx context.Context, status string, offset, limit int) (*imserver.ReportList, error) {
	list, err := s.im.ListReports(ctx, status, offset, limit)
	if err != nil {
		return nil, imFailure("list reports", err)
	}
	return list, nil
}

// ResolveReport 处理举报：ignore 只标记；ban 封禁被举报人（IM 与 Paircast 账号都禁用），管理员不能被封禁。
func (s *Service) ResolveReport(ctx context.Context, actor *User, id int64, action string) error {
	switch action {
	case "ignore":
		if _, err := s.im.ResolveReport(ctx, id, action, actor.IMUID); err != nil {
			return imFailure("resolve report", err)
		}
		return nil
	case "ban":
	default:
		return fail(http.StatusBadRequest, "action must be ignore or ban")
	}
	rep, err := s.im.GetReport(ctx, id)
	if err != nil {
		return imFailure("get report", err)
	}
	t, err := s.store.GetByIMUID(ctx, rep.Target.UID)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return err
	}
	if t != nil && t.IsAdmin() {
		return fail(http.StatusForbidden, "cannot ban an admin")
	}
	if _, err := s.im.ResolveReport(ctx, id, action, actor.IMUID); err != nil {
		return imFailure("resolve report", err)
	}
	if t == nil {
		return nil
	}
	return s.markDisabled(ctx, t.ID, true)
}

// imFailure 把 IM 的 404 / 400 原样转给客户端，其他错误记为 IM 不可用。
func imFailure(op string, err error) error {
	var apiErr *imserver.APIError
	if errors.As(err, &apiErr) {
		switch apiErr.Status {
		case http.StatusNotFound:
			return fail(http.StatusNotFound, "report not found")
		case http.StatusBadRequest:
			return fail(http.StatusBadRequest, apiErr.Message)
		case http.StatusServiceUnavailable:
			return fail(http.StatusServiceUnavailable, "moderation not available")
		}
	}
	log.Printf("[account] %s: %v", op, err)
	return errIMUnavailable
}

// 不含 0/O、1/l/I 等易混字符，方便照着邮件手输。
const passwordAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"

const initialPasswordLen = 16

func randomPassword(n int) (string, error) {
	max := big.NewInt(int64(len(passwordAlphabet)))
	out := make([]byte, n)
	for i := range out {
		idx, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", err
		}
		out[i] = passwordAlphabet[idx.Int64()]
	}
	return string(out), nil
}
