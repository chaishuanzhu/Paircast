package account

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"

	"github.com/chaishuanzhu/GO-IM/pkg/imserver"
)

// Mux 是 Register 需要的路由注册能力（*http.ServeMux 实现）。
type Mux interface {
	HandleFunc(pattern string, handler func(http.ResponseWriter, *http.Request))
}

// Handler 是账号接口（/account/*）与管理后台（/console/*）。
type Handler struct {
	svc *Service
	// imURL 是客户端连接 IM 的地址，空 = 与 Paircast 服务同源。
	imURL string
}

// NewHandler 创建 HTTP 层。
func NewHandler(svc *Service, imPublicURL string) *Handler {
	return &Handler{svc: svc, imURL: strings.TrimRight(imPublicURL, "/")}
}

// Register 挂载 /account/* 与 /console/*。
func (h *Handler) Register(mux Mux) {
	mux.HandleFunc("/account/login", h.HandleLogin)
	mux.HandleFunc("/account/session", h.HandleSession)
	mux.HandleFunc("/account/password", h.HandlePassword)
	mux.HandleFunc("/account/profile", h.HandleProfile)
	mux.HandleFunc("/account/delete", h.HandleDelete)

	mux.HandleFunc("/console/users", h.HandleUsers)
	mux.HandleFunc("/console/users/create", h.HandleUserCreate)
	mux.HandleFunc("/console/users/disable", h.HandleUserDisable)
	mux.HandleFunc("/console/users/delete", h.HandleUserDelete)
	mux.HandleFunc("/console/reports", h.HandleReports)
	mux.HandleFunc("/console/reports/resolve", h.HandleReportResolve)
}

// Authenticate 用 Paircast 会话令牌认证请求（/media/*、/room/* 用），返回 IM uid。
// 令牌取自 token 参数（查询或表单）或 Authorization: Bearer；带 uid 参数时必须与账号一致。
func (h *Handler) Authenticate(w http.ResponseWriter, r *http.Request) (string, bool) {
	u, ok := h.auth(w, r)
	if !ok {
		return "", false
	}
	if uid := r.FormValue("uid"); uid != "" && uid != u.IMUID {
		http.Error(w, "uid does not match token", http.StatusForbidden)
		return "", false
	}
	return u.IMUID, true
}

func (h *Handler) auth(w http.ResponseWriter, r *http.Request) (*User, bool) {
	token := r.FormValue("token")
	if token == "" {
		token = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	}
	if token == "" {
		http.Error(w, "missing token", http.StatusUnauthorized)
		return nil, false
	}
	u, err := h.svc.Verify(r.Context(), token)
	if err != nil {
		writeError(w, err)
		return nil, false
	}
	return u, true
}

func (h *Handler) adminAuth(w http.ResponseWriter, r *http.Request, method string) (*User, bool) {
	if r.Method != method {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return nil, false
	}
	u, ok := h.auth(w, r)
	if !ok {
		return nil, false
	}
	if !u.IsAdmin() {
		http.Error(w, "admin required", http.StatusForbidden)
		return nil, false
	}
	return u, true
}

func writeError(w http.ResponseWriter, err error) {
	var e *Error
	if errors.As(err, &e) {
		http.Error(w, e.Message, e.Status)
		return
	}
	log.Printf("[account] error: %v", err)
	http.Error(w, "internal error", http.StatusInternalServerError)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func avatarURL(fileID int64) string {
	if fileID <= 0 {
		return ""
	}
	return "/avatar/" + strconv.FormatInt(fileID, 10)
}

// ProfileView 是自己的资料；uid 是 IM uid，avatar_url 相对于 IM 地址。
type ProfileView struct {
	UID                string `json:"uid"`
	Nickname           string `json:"nickname"`
	Email              string `json:"email"`
	AvatarURL          string `json:"avatar_url,omitempty"`
	Role               string `json:"role"`
	MustChangePassword bool   `json:"must_change_password"`
}

func profileView(u *User) ProfileView {
	return ProfileView{UID: u.IMUID, Nickname: u.Nickname, Email: u.Email, AvatarURL: avatarURL(u.AvatarFileID), Role: u.Role, MustChangePassword: u.MustChangePassword}
}

// IMView 是客户端连接 IM 需要的信息；url 为空表示与 Paircast 服务同源。
type IMView struct {
	URL       string `json:"url"`
	UID       string `json:"uid"`
	Token     string `json:"token"`
	ExpiresAt int64  `json:"expires_at,omitempty"`
}

// SessionView 是登录 / 会话接口的响应。
type SessionView struct {
	ProfileView
	Token string `json:"token"`
	IM    IMView `json:"im"`
}

func (h *Handler) writeSession(w http.ResponseWriter, r *http.Request, u *User, token string) {
	t, err := h.svc.IMToken(r.Context(), u)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, SessionView{
		ProfileView: profileView(u),
		Token:       token,
		IM:          IMView{URL: h.imURL, UID: t.UID, Token: t.Token, ExpiresAt: t.ExpiresAt},
	})
}

// HandleLogin 登录。POST account（邮箱或 IM uid）、password。
func (h *Handler) HandleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	u, err := h.svc.Login(r.Context(), r.FormValue("account"), r.FormValue("password"))
	if err != nil {
		writeError(w, err)
		return
	}
	h.writeSession(w, r, u, h.svc.Session(u))
}

// HandleSession 校验会话并返回最新资料与新的 IM 令牌（启动恢复登录、IM 令牌过期时调用）。GET。
func (h *Handler) HandleSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	u, ok := h.auth(w, r)
	if !ok {
		return
	}
	token := r.FormValue("token")
	if token == "" {
		token = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	}
	h.writeSession(w, r, u, token)
}

// HandlePassword 修改密码。POST old_password、new_password；返回新的会话令牌（旧令牌全部失效）。
func (h *Handler) HandlePassword(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	u, ok := h.auth(w, r)
	if !ok {
		return
	}
	u, err := h.svc.ChangePassword(r.Context(), u, r.FormValue("old_password"), r.FormValue("new_password"))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]string{"status": "ok", "token": h.svc.Session(u)})
}

// HandleProfile GET 返回自己的资料；POST nickname 和 / 或 avatar_file_id（IM /upload 得到的文件 ID，0 清除）。
func (h *Handler) HandleProfile(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	u, ok := h.auth(w, r)
	if !ok {
		return
	}
	if r.Method == http.MethodPost {
		var nickname *string
		var avatar *int64
		if _, set := r.PostForm["nickname"]; set {
			n := strings.TrimSpace(r.PostForm.Get("nickname"))
			nickname = &n
		}
		if raw, set := r.PostForm["avatar_file_id"]; set && len(raw) > 0 {
			id, err := strconv.ParseInt(strings.TrimSpace(raw[0]), 10, 64)
			if err != nil {
				http.Error(w, "invalid avatar_file_id", http.StatusBadRequest)
				return
			}
			avatar = &id
		}
		var err error
		if u, err = h.svc.UpdateProfile(r.Context(), u, nickname, avatar); err != nil {
			writeError(w, err)
			return
		}
	}
	writeJSON(w, profileView(u))
}

// HandleDelete 注销自己的账号。POST password。
func (h *Handler) HandleDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	u, ok := h.auth(w, r)
	if !ok {
		return
	}
	if err := h.svc.DeleteSelf(r.Context(), u, r.FormValue("password")); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]string{"status": "ok"})
}

// AdminUserView 是后台用户列表的一行。
type AdminUserView struct {
	UID        string `json:"uid"`
	Nickname   string `json:"nickname"`
	Email      string `json:"email"`
	AvatarURL  string `json:"avatar_url,omitempty"`
	Role       string `json:"role"`
	IsDisabled bool   `json:"is_disabled"`
	CreatedAt  int64  `json:"created_at"`
}

func adminUserView(u *User) AdminUserView {
	return AdminUserView{UID: u.IMUID, Nickname: u.Nickname, Email: u.Email, AvatarURL: avatarURL(u.AvatarFileID), Role: u.Role, IsDisabled: u.Disabled, CreatedAt: u.CreatedAt}
}

func pageParams(r *http.Request) (offset, limit int) {
	limit = 50
	if v, err := strconv.Atoi(r.FormValue("offset")); err == nil && v > 0 {
		offset = v
	}
	if v, err := strconv.Atoi(r.FormValue("limit")); err == nil && v > 0 && v <= 200 {
		limit = v
	}
	return offset, limit
}

// HandleUsers 分页列出账号。GET offset、limit（≤ 200）。
func (h *Handler) HandleUsers(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.adminAuth(w, r, http.MethodGet); !ok {
		return
	}
	offset, limit := pageParams(r)
	users, total, err := h.svc.Users(r.Context(), offset, limit)
	if err != nil {
		writeError(w, err)
		return
	}
	views := make([]AdminUserView, 0, len(users))
	for _, u := range users {
		views = append(views, adminUserView(u))
	}
	writeJSON(w, map[string]any{"users": views, "total": total, "offset": offset, "limit": limit})
}

// HandleUserCreate 建号。POST email、nickname?；未能发信时响应带 initial_password。
func (h *Handler) HandleUserCreate(w http.ResponseWriter, r *http.Request) {
	actor, ok := h.adminAuth(w, r, http.MethodPost)
	if !ok {
		return
	}
	c, err := h.svc.CreateUser(r.Context(), r.FormValue("email"), r.FormValue("nickname"), RoleUser)
	if err != nil {
		writeError(w, err)
		return
	}
	log.Printf("[account] admin %s created %s (im uid %s)", actor.IMUID, maskEmail(c.User.Email), c.User.IMUID)
	resp := map[string]any{"status": "ok", "user": adminUserView(c.User), "mailed": c.Mailed}
	if !c.Mailed {
		resp["initial_password"] = c.InitialPassword
	}
	writeJSON(w, resp)
}

// HandleUserDisable 禁用 / 启用账号。POST target_uid（IM uid）、disabled。
func (h *Handler) HandleUserDisable(w http.ResponseWriter, r *http.Request) {
	actor, ok := h.adminAuth(w, r, http.MethodPost)
	if !ok {
		return
	}
	disabled, err := strconv.ParseBool(r.FormValue("disabled"))
	if err != nil {
		http.Error(w, "disabled must be true or false", http.StatusBadRequest)
		return
	}
	if err := h.svc.SetDisabled(r.Context(), actor, r.FormValue("target_uid"), disabled); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]any{"status": "ok", "disabled": disabled})
}

// HandleUserDelete 删除账号。POST target_uid（IM uid）。
func (h *Handler) HandleUserDelete(w http.ResponseWriter, r *http.Request) {
	actor, ok := h.adminAuth(w, r, http.MethodPost)
	if !ok {
		return
	}
	if err := h.svc.DeleteUser(r.Context(), actor, r.FormValue("target_uid")); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]string{"status": "ok"})
}

// ReportView 是后台举报列表的一行（被举报人的禁用状态取 IM 侧）。
type ReportView struct {
	ID               int64  `json:"id"`
	ReporterUID      string `json:"reporter_uid"`
	ReporterNickname string `json:"reporter_nickname"`
	TargetUID        string `json:"target_uid"`
	TargetNickname   string `json:"target_nickname"`
	TargetDisabled   bool   `json:"target_disabled"`
	MessageID        string `json:"message_id,omitempty"`
	Context          string `json:"context,omitempty"`
	Content          string `json:"content"`
	Status           string `json:"status"`
	HandledBy        string `json:"handled_by,omitempty"`
	CreatedAt        int64  `json:"created_at"`
	HandledAt        int64  `json:"handled_at,omitempty"`
}

func reportView(r imserver.Report) ReportView {
	return ReportView{
		ID: r.ID, ReporterUID: r.Reporter.UID, ReporterNickname: r.Reporter.Nickname,
		TargetUID: r.Target.UID, TargetNickname: r.Target.Nickname, TargetDisabled: r.Target.Disabled,
		MessageID: r.MessageID, Context: r.Context, Content: r.Content, Status: r.Status,
		HandledBy: r.HandledBy, CreatedAt: r.CreatedAt, HandledAt: r.HandledAt,
	}
}

// HandleReports 分页列出举报。GET status（pending | handled | all）、offset、limit。
func (h *Handler) HandleReports(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.adminAuth(w, r, http.MethodGet); !ok {
		return
	}
	offset, limit := pageParams(r)
	list, err := h.svc.Reports(r.Context(), r.FormValue("status"), offset, limit)
	if err != nil {
		writeError(w, err)
		return
	}
	views := make([]ReportView, 0, len(list.Reports))
	for _, rep := range list.Reports {
		views = append(views, reportView(rep))
	}
	writeJSON(w, map[string]any{"reports": views, "total": list.Total, "pending": list.Pending, "offset": offset, "limit": limit})
}

// HandleReportResolve 处理举报。POST id、action（ignore | ban）。
func (h *Handler) HandleReportResolve(w http.ResponseWriter, r *http.Request) {
	actor, ok := h.adminAuth(w, r, http.MethodPost)
	if !ok {
		return
	}
	id, err := strconv.ParseInt(r.FormValue("id"), 10, 64)
	if err != nil || id <= 0 {
		http.Error(w, "id required", http.StatusBadRequest)
		return
	}
	action := r.FormValue("action")
	if err := h.svc.ResolveReport(r.Context(), actor, id, action); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]string{"status": "ok"})
}
