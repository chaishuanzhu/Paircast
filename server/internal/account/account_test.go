package account

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/chaishuanzhu/GO-IM/pkg/imserver"
)

type fakeIM struct {
	mu       sync.Mutex
	users    map[string]*imserver.User // external_id → user
	disabled map[string]bool           // im uid
	deleted  []string
	reports  map[int64]*imserver.Report
	resolved map[int64]string
	down     bool
}

func newFakeIM() *fakeIM {
	return &fakeIM{users: map[string]*imserver.User{}, disabled: map[string]bool{}, reports: map[int64]*imserver.Report{}, resolved: map[int64]string{}}
}

func (f *fakeIM) ImportUser(_ context.Context, u imserver.ImportUser) (*imserver.User, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.down {
		return nil, fmt.Errorf("connection refused")
	}
	if u.AvatarFileID != nil && *u.AvatarFileID == 666 {
		return nil, &imserver.APIError{Status: http.StatusBadRequest, Message: "avatar file not found"}
	}
	x, ok := f.users[u.ExternalID]
	if !ok {
		x = &imserver.User{UID: fmt.Sprint(100000 + len(f.users)), ExternalID: u.ExternalID, Created: true}
		f.users[u.ExternalID] = x
	}
	if u.Nickname != nil {
		x.Nickname = *u.Nickname
	}
	if u.AvatarFileID != nil {
		x.AvatarFileID = *u.AvatarFileID
	}
	c := *x
	return &c, nil
}

func (f *fakeIM) IssueToken(_ context.Context, user imserver.UserRef, _ time.Duration) (*imserver.Token, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.down {
		return nil, fmt.Errorf("connection refused")
	}
	return &imserver.Token{UID: user.UID, Token: "im-" + user.UID, ExpiresAt: 1}, nil
}

func (f *fakeIM) SetUserDisabled(_ context.Context, user imserver.UserRef, disabled bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.disabled[user.UID] = disabled
	return nil
}

func (f *fakeIM) DeleteUser(_ context.Context, user imserver.UserRef) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deleted = append(f.deleted, user.UID)
	return nil
}

func (f *fakeIM) ListReports(_ context.Context, status string, _, _ int) (*imserver.ReportList, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := &imserver.ReportList{}
	for _, r := range f.reports {
		if r.Status == imserver.ReportPending {
			out.Pending++
		}
		if status == "" || status == r.Status {
			out.Reports = append(out.Reports, *r)
		}
	}
	out.Total = len(out.Reports)
	return out, nil
}

func (f *fakeIM) GetReport(_ context.Context, id int64) (*imserver.Report, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	r, ok := f.reports[id]
	if !ok {
		return nil, &imserver.APIError{Status: http.StatusNotFound, Message: "report not found"}
	}
	c := *r
	return &c, nil
}

func (f *fakeIM) ResolveReport(_ context.Context, id int64, action, handledBy string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	r, ok := f.reports[id]
	if !ok {
		return "", &imserver.APIError{Status: http.StatusNotFound, Message: "report not found"}
	}
	f.resolved[id] = action + " by " + handledBy
	r.Status = map[string]string{"ignore": imserver.ReportIgnored, "ban": imserver.ReportBanned}[action]
	if action == "ban" {
		f.disabled[r.Target.UID] = true
	}
	return r.Status, nil
}

type fakeMailer struct {
	mu   sync.Mutex
	sent map[string]string // to → text
}

func (m *fakeMailer) Send(_ context.Context, to, _, text, _ string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sent[to] = text
	return nil
}

type env struct {
	svc  *Service
	h    *Handler
	im   *fakeIM
	mux  *http.ServeMux
	mail *fakeMailer
}

func newEnv(t *testing.T, withMail bool) *env {
	t.Helper()
	e := &env{im: newFakeIM(), mux: http.NewServeMux()}
	var mailer Mailer
	if withMail {
		e.mail = &fakeMailer{sent: map[string]string{}}
		mailer = e.mail
	}
	svc, err := NewService(NewMemoryStore(), e.im, mailer, Options{SessionSecret: "0123456789abcdef"})
	if err != nil {
		t.Fatal(err)
	}
	e.svc = svc
	e.h = NewHandler(svc, "https://im.example")
	e.h.Register(e.mux)
	return e
}

func (e *env) do(t *testing.T, method, path, token string, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	var req *http.Request
	if method == http.MethodGet {
		req = httptest.NewRequest(method, path+"?"+form.Encode(), nil)
	} else {
		req = httptest.NewRequest(method, path, strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	e.mux.ServeHTTP(rec, req)
	return rec
}

func (e *env) ok(t *testing.T, method, path, token string, form url.Values) map[string]any {
	t.Helper()
	rec := e.do(t, method, path, token, form)
	if rec.Code != http.StatusOK {
		t.Fatalf("%s %s: %d %s", method, path, rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func expect(t *testing.T, rec *httptest.ResponseRecorder, code int, body string) {
	t.Helper()
	if rec.Code != code || !strings.Contains(rec.Body.String(), body) {
		t.Fatalf("got %d %q, want %d %q", rec.Code, rec.Body.String(), code, body)
	}
}

// adminSession 建好管理员并完成首次改密，返回会话令牌。
func (e *env) adminSession(t *testing.T) string {
	t.Helper()
	ctx := context.Background()
	c, err := e.svc.CreateUser(ctx, "admin@example.com", "", RoleAdmin)
	if err != nil {
		t.Fatal(err)
	}
	pass := c.InitialPassword
	if c.Mailed {
		_, rest, _ := strings.Cut(e.mail.sent["admin@example.com"], "初始密码：")
		pass, _, _ = strings.Cut(rest, "\n")
	}
	login := e.ok(t, http.MethodPost, "/account/login", "", url.Values{"account": {"admin@example.com"}, "password": {pass}})
	return e.ok(t, http.MethodPost, "/account/password", login["token"].(string),
		url.Values{"old_password": {pass}, "new_password": {"admin-pass"}})["token"].(string)
}

func TestLoginSessionAndPasswordChange(t *testing.T) {
	e := newEnv(t, false)
	ctx := context.Background()
	c, err := e.svc.CreateUser(ctx, "Alice@Example.com", "", RoleUser)
	if err != nil {
		t.Fatal(err)
	}
	if c.Mailed || len(c.InitialPassword) != initialPasswordLen || c.User.Nickname != "alice" || c.User.IMUID == "" {
		t.Fatalf("created: %+v %+v", c, c.User)
	}

	expect(t, e.do(t, http.MethodPost, "/account/login", "", url.Values{"account": {"alice@example.com"}, "password": {"wrong"}}),
		http.StatusUnauthorized, "invalid account or password")
	login := e.ok(t, http.MethodPost, "/account/login", "", url.Values{"account": {"alice@example.com"}, "password": {c.InitialPassword}})
	im := login["im"].(map[string]any)
	if login["uid"] != c.User.IMUID || login["must_change_password"] != true || login["role"] != RoleUser ||
		im["url"] != "https://im.example" || im["token"] != "im-"+c.User.IMUID {
		t.Fatalf("login: %v", login)
	}
	// IM uid 也能登录。
	e.ok(t, http.MethodPost, "/account/login", "", url.Values{"account": {c.User.IMUID}, "password": {c.InitialPassword}})

	token := login["token"].(string)
	sess := e.ok(t, http.MethodGet, "/account/session", token, nil)
	if sess["token"] != token || sess["email"] != "alice@example.com" {
		t.Fatalf("session: %v", sess)
	}

	expect(t, e.do(t, http.MethodPost, "/account/password", token, url.Values{"old_password": {"nope"}, "new_password": {"secret1"}}),
		http.StatusUnauthorized, "invalid current password")
	expect(t, e.do(t, http.MethodPost, "/account/password", token, url.Values{"old_password": {c.InitialPassword}, "new_password": {"123"}}),
		http.StatusBadRequest, "at least 6")
	fresh := e.ok(t, http.MethodPost, "/account/password", token, url.Values{"old_password": {c.InitialPassword}, "new_password": {"secret1"}})["token"].(string)
	expect(t, e.do(t, http.MethodGet, "/account/session", token, nil), http.StatusUnauthorized, "token revoked")
	if e.ok(t, http.MethodGet, "/account/session", fresh, nil)["must_change_password"] != false {
		t.Fatal("must_change_password not cleared")
	}
	expect(t, e.do(t, http.MethodGet, "/account/session", "pc1.garbage.sig", nil), http.StatusUnauthorized, "invalid token")
	expect(t, e.do(t, http.MethodGet, "/account/session", "", nil), http.StatusUnauthorized, "missing token")
}

func TestProfileSyncsToIM(t *testing.T) {
	e := newEnv(t, false)
	c, _ := e.svc.CreateUser(context.Background(), "bob@example.com", "Bob", RoleUser)
	token := e.svc.Session(c.User)

	got := e.ok(t, http.MethodPost, "/account/profile", token, url.Values{"nickname": {" Bobby "}, "avatar_file_id": {"42"}})
	if got["nickname"] != "Bobby" || got["avatar_url"] != "/avatar/42" {
		t.Fatalf("profile: %v", got)
	}
	if u := e.im.users["1"]; u.Nickname != "Bobby" || u.AvatarFileID != 42 {
		t.Fatalf("im user: %+v", u)
	}
	expect(t, e.do(t, http.MethodPost, "/account/profile", token, url.Values{"avatar_file_id": {"666"}}), http.StatusBadRequest, "avatar file not found")
	expect(t, e.do(t, http.MethodPost, "/account/profile", token, url.Values{"nickname": {""}}), http.StatusBadRequest, "nickname required")
	expect(t, e.do(t, http.MethodPost, "/account/profile", token, url.Values{}), http.StatusBadRequest, "nothing to update")
	if got := e.ok(t, http.MethodGet, "/account/profile", token, nil); got["avatar_url"] != "/avatar/42" {
		t.Fatalf("profile after failed update: %v", got)
	}
}

func TestIMOutageAtCreateIsRepairedOnLogin(t *testing.T) {
	e := newEnv(t, false)
	e.im.down = true
	_, err := e.svc.CreateUser(context.Background(), "carol@example.com", "", RoleUser)
	if err == nil {
		t.Fatal("create succeeded while IM is down")
	}
	u, _ := e.svc.store.GetByEmail(context.Background(), "carol@example.com")
	if u == nil || u.IMUID != "" {
		t.Fatalf("stored: %+v", u)
	}
	e.im.down = false
	if _, err := e.svc.IMToken(context.Background(), u); err != nil {
		t.Fatal(err)
	}
	if u, _ = e.svc.store.Get(context.Background(), u.ID); u.IMUID == "" {
		t.Fatal("im uid not repaired")
	}
}

func TestBootstrapAdmin(t *testing.T) {
	e := newEnv(t, true)
	ctx := context.Background()
	if err := e.svc.BootstrapAdmin(ctx, "root@example.com"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(e.mail.sent["root@example.com"], "初始密码") {
		t.Fatalf("mail: %v", e.mail.sent)
	}
	u, _ := e.svc.store.GetByEmail(ctx, "root@example.com")
	if !u.IsAdmin() || !u.MustChangePassword {
		t.Fatalf("admin: %+v", u)
	}
	if err := e.svc.BootstrapAdmin(ctx, "root@example.com"); err != nil {
		t.Fatal(err)
	}

	e.svc.CreateUser(ctx, "dave@example.com", "", RoleUser)
	if err := e.svc.BootstrapAdmin(ctx, "dave@example.com"); err != nil {
		t.Fatal(err)
	}
	if d, _ := e.svc.store.GetByEmail(ctx, "dave@example.com"); !d.IsAdmin() {
		t.Fatal("existing account not promoted")
	}
	if err := e.svc.BootstrapAdmin(ctx, "not-an-email"); err == nil {
		t.Fatal("invalid email accepted")
	}
}

func TestConsoleUsers(t *testing.T) {
	e := newEnv(t, false)
	admin := e.adminSession(t)

	created := e.ok(t, http.MethodPost, "/console/users/create", admin, url.Values{"email": {"erin@example.com"}, "nickname": {"Erin"}})
	user := created["user"].(map[string]any)
	pass, _ := created["initial_password"].(string)
	if created["mailed"] != false || pass == "" || user["nickname"] != "Erin" {
		t.Fatalf("create: %v", created)
	}
	erinUID := user["uid"].(string)
	expect(t, e.do(t, http.MethodPost, "/console/users/create", admin, url.Values{"email": {"erin@example.com"}}), http.StatusConflict, "email already registered")
	expect(t, e.do(t, http.MethodPost, "/console/users/create", admin, url.Values{"email": {"nope"}}), http.StatusBadRequest, "invalid email")

	list := e.ok(t, http.MethodGet, "/console/users", admin, url.Values{"limit": {"10"}})
	if list["total"] != float64(2) || list["users"].([]any)[0].(map[string]any)["uid"] != erinUID {
		t.Fatalf("list: %v", list)
	}

	erin := e.ok(t, http.MethodPost, "/account/login", "", url.Values{"account": {"erin@example.com"}, "password": {pass}})["token"].(string)
	expect(t, e.do(t, http.MethodGet, "/console/users", erin, nil), http.StatusForbidden, "admin required")

	e.ok(t, http.MethodPost, "/console/users/disable", admin, url.Values{"target_uid": {erinUID}, "disabled": {"true"}})
	if !e.im.disabled[erinUID] {
		t.Fatal("im user not disabled")
	}
	expect(t, e.do(t, http.MethodGet, "/account/session", erin, nil), http.StatusUnauthorized, "account disabled")
	expect(t, e.do(t, http.MethodPost, "/account/login", "", url.Values{"account": {"erin@example.com"}, "password": {pass}}), http.StatusForbidden, "account disabled")
	e.ok(t, http.MethodPost, "/console/users/disable", admin, url.Values{"target_uid": {erinUID}, "disabled": {"false"}})
	e.ok(t, http.MethodPost, "/account/login", "", url.Values{"account": {"erin@example.com"}, "password": {pass}})

	adminUID := e.ok(t, http.MethodGet, "/account/session", admin, nil)["uid"].(string)
	expect(t, e.do(t, http.MethodPost, "/console/users/disable", admin, url.Values{"target_uid": {adminUID}, "disabled": {"true"}}), http.StatusBadRequest, "yourself")
	expect(t, e.do(t, http.MethodPost, "/console/users/delete", admin, url.Values{"target_uid": {adminUID}}), http.StatusBadRequest, "yourself")
	expect(t, e.do(t, http.MethodPost, "/console/users/delete", admin, url.Values{"target_uid": {"999999"}}), http.StatusNotFound, "user not found")

	e.ok(t, http.MethodPost, "/console/users/delete", admin, url.Values{"target_uid": {erinUID}})
	if len(e.im.deleted) != 1 || e.im.deleted[0] != erinUID {
		t.Fatalf("im deleted: %v", e.im.deleted)
	}
	expect(t, e.do(t, http.MethodGet, "/account/session", erin, nil), http.StatusUnauthorized, "account deleted")
}

func TestCreateUserMailsPassword(t *testing.T) {
	e := newEnv(t, true)
	admin := e.adminSession(t)
	created := e.ok(t, http.MethodPost, "/console/users/create", admin, url.Values{"email": {"frank@example.com"}})
	if created["mailed"] != true || created["initial_password"] != nil || e.mail.sent["frank@example.com"] == "" {
		t.Fatalf("create: %v", created)
	}
}

func TestDeleteSelf(t *testing.T) {
	e := newEnv(t, false)
	admin := e.adminSession(t)
	expect(t, e.do(t, http.MethodPost, "/account/delete", admin, url.Values{"password": {"admin-pass"}}), http.StatusForbidden, "admin accounts cannot be deleted here")

	c, _ := e.svc.CreateUser(context.Background(), "gina@example.com", "", RoleUser)
	token := e.svc.Session(c.User)
	expect(t, e.do(t, http.MethodPost, "/account/delete", token, url.Values{"password": {"wrong"}}), http.StatusUnauthorized, "invalid password")
	e.ok(t, http.MethodPost, "/account/delete", token, url.Values{"password": {c.InitialPassword}})
	if len(e.im.deleted) != 1 || e.im.deleted[0] != c.User.IMUID {
		t.Fatalf("im deleted: %v", e.im.deleted)
	}
	expect(t, e.do(t, http.MethodGet, "/account/session", token, nil), http.StatusUnauthorized, "account deleted")
}

func TestConsoleReports(t *testing.T) {
	e := newEnv(t, false)
	admin := e.adminSession(t)
	ctx := context.Background()
	adminUser, _ := e.svc.store.GetByEmail(ctx, "admin@example.com")
	hank, _ := e.svc.CreateUser(ctx, "hank@example.com", "Hank", RoleUser)
	e.im.reports[1] = &imserver.Report{ID: 1, Content: "spam", Status: imserver.ReportPending, Context: "g_1",
		Reporter: imserver.User{UID: adminUser.IMUID, Nickname: "admin"}, Target: imserver.User{UID: hank.User.IMUID, Nickname: "Hank"}}
	e.im.reports[2] = &imserver.Report{ID: 2, Content: "rude", Status: imserver.ReportPending,
		Reporter: imserver.User{UID: hank.User.IMUID}, Target: imserver.User{UID: adminUser.IMUID}}

	list := e.ok(t, http.MethodGet, "/console/reports", admin, url.Values{"status": {"pending"}})
	if list["pending"] != float64(2) || len(list["reports"].([]any)) != 2 {
		t.Fatalf("list: %v", list)
	}

	expect(t, e.do(t, http.MethodPost, "/console/reports/resolve", admin, url.Values{"id": {"2"}, "action": {"ban"}}), http.StatusForbidden, "cannot ban an admin")
	expect(t, e.do(t, http.MethodPost, "/console/reports/resolve", admin, url.Values{"id": {"9"}, "action": {"ban"}}), http.StatusNotFound, "report not found")
	expect(t, e.do(t, http.MethodPost, "/console/reports/resolve", admin, url.Values{"id": {"1"}, "action": {"nuke"}}), http.StatusBadRequest, "action must be")

	hankToken := e.svc.Session(hank.User)
	e.ok(t, http.MethodPost, "/console/reports/resolve", admin, url.Values{"id": {"1"}, "action": {"ban"}})
	if e.im.resolved[1] != "ban by "+adminUser.IMUID {
		t.Fatalf("resolved: %v", e.im.resolved)
	}
	expect(t, e.do(t, http.MethodGet, "/account/session", hankToken, nil), http.StatusUnauthorized, "account disabled")
	e.ok(t, http.MethodPost, "/console/reports/resolve", admin, url.Values{"id": {"2"}, "action": {"ignore"}})
}

func TestAuthenticate(t *testing.T) {
	e := newEnv(t, false)
	c, _ := e.svc.CreateUser(context.Background(), "ivy@example.com", "", RoleUser)
	token := e.svc.Session(c.User)
	call := func(query string) (int, string) {
		rec := httptest.NewRecorder()
		uid, _ := e.h.Authenticate(rec, httptest.NewRequest(http.MethodGet, "/media/sources?"+query, nil))
		return rec.Code, uid
	}
	if code, uid := call("token=" + token + "&uid=" + c.User.IMUID); code != http.StatusOK || uid != c.User.IMUID {
		t.Fatalf("auth: %d %q", code, uid)
	}
	if code, _ := call("token=" + token + "&uid=1"); code != http.StatusForbidden {
		t.Fatalf("uid mismatch: %d", code)
	}
	if code, _ := call("token=im-token"); code != http.StatusUnauthorized {
		t.Fatalf("bad token: %d", code)
	}
}
