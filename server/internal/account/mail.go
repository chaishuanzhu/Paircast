package account

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"html"
	"mime"
	"net"
	"net/mail"
	"net/smtp"
	"strconv"
	"strings"
	"time"
)

// Mailer 发送一封同时带纯文本与 HTML 正文的邮件。
type Mailer interface {
	Send(ctx context.Context, to, subject, text, html string) error
}

// MailConfig 是 SMTP 配置；密码只建议用环境变量 PAIRCAST_MAIL_PASSWORD 提供。
type MailConfig struct {
	Enabled  bool   `json:"enabled"`
	Host     string `json:"host"`
	Port     int    `json:"port"` // 465 用隐式 TLS，其他端口在服务器支持时升级 STARTTLS
	Username string `json:"username"`
	Password string `json:"password"`
	From     string `json:"from"` // 默认 username，可写 "Paircast <noreply@example.com>"
}

// SMTPMailer 通过 SMTP 发信。
type SMTPMailer struct {
	host     string
	port     int
	username string
	password string
	from     *mail.Address
}

// NewSMTPMailer 校验配置并创建 SMTPMailer。
func NewSMTPMailer(cfg MailConfig) (*SMTPMailer, error) {
	if cfg.Host == "" || cfg.Port == 0 || cfg.Username == "" {
		return nil, fmt.Errorf("mail: host, port and username are required")
	}
	fromStr := cfg.From
	if fromStr == "" {
		fromStr = cfg.Username
	}
	from, err := mail.ParseAddress(fromStr)
	if err != nil {
		return nil, fmt.Errorf("mail: invalid from %q: %w", fromStr, err)
	}
	return &SMTPMailer{host: cfg.Host, port: cfg.Port, username: cfg.Username, password: cfg.Password, from: from}, nil
}

// Send 实现 Mailer。
func (m *SMTPMailer) Send(ctx context.Context, to, subject, text, body string) error {
	addr := net.JoinHostPort(m.host, strconv.Itoa(m.port))
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	var conn net.Conn
	var err error
	if m.port == 465 {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{ServerName: m.host})
	} else {
		conn, err = dialer.DialContext(ctx, "tcp", addr)
	}
	if err != nil {
		return fmt.Errorf("smtp dial: %w", err)
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	c, err := smtp.NewClient(conn, m.host)
	if err != nil {
		conn.Close()
		return fmt.Errorf("smtp handshake: %w", err)
	}
	defer c.Close()
	if m.port != 465 {
		if ok, _ := c.Extension("STARTTLS"); ok {
			if err := c.StartTLS(&tls.Config{ServerName: m.host}); err != nil {
				return fmt.Errorf("smtp starttls: %w", err)
			}
		}
	}
	if m.password != "" {
		if err := c.Auth(smtp.PlainAuth("", m.username, m.password, m.host)); err != nil {
			return fmt.Errorf("smtp auth: %w", err)
		}
	}
	if err := c.Mail(m.from.Address); err != nil {
		return fmt.Errorf("smtp mail from: %w", err)
	}
	if err := c.Rcpt(to); err != nil {
		return fmt.Errorf("smtp rcpt: %w", err)
	}
	w, err := c.Data()
	if err != nil {
		return fmt.Errorf("smtp data: %w", err)
	}
	if _, err := w.Write(buildMessage(m.from, to, subject, text, body)); err != nil {
		return fmt.Errorf("smtp write: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("smtp send: %w", err)
	}
	return c.Quit()
}

// buildMessage 生成 multipart/alternative 邮件，标题与正文均以 UTF-8 编码。
func buildMessage(from *mail.Address, to, subject, text, body string) []byte {
	boundary := randomHex(12)
	var b bytes.Buffer
	header := func(k, v string) { fmt.Fprintf(&b, "%s: %s\r\n", k, v) }
	header("From", from.String())
	header("To", to)
	header("Subject", mime.BEncoding.Encode("UTF-8", subject))
	header("Date", time.Now().Format(time.RFC1123Z))
	header("Message-ID", fmt.Sprintf("<%s@%s>", randomHex(16), domainOf(from.Address)))
	header("MIME-Version", "1.0")
	header("Content-Type", `multipart/alternative; boundary="`+boundary+`"`)
	b.WriteString("\r\n")
	for _, part := range []struct{ typ, body string }{{"text/plain", text}, {"text/html", body}} {
		fmt.Fprintf(&b, "--%s\r\nContent-Type: %s; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n", boundary, part.typ)
		enc := base64.StdEncoding.EncodeToString([]byte(part.body))
		for len(enc) > 76 {
			b.WriteString(enc[:76] + "\r\n")
			enc = enc[76:]
		}
		b.WriteString(enc + "\r\n")
	}
	fmt.Fprintf(&b, "--%s--\r\n", boundary)
	return b.Bytes()
}

func domainOf(addr string) string {
	if i := strings.LastIndexByte(addr, '@'); i >= 0 {
		return addr[i+1:]
	}
	return "localhost"
}

func randomHex(n int) string {
	buf := make([]byte, n)
	_, _ = rand.Read(buf)
	return hex.EncodeToString(buf)
}

func initialPasswordMail(email, password string, admin bool) (subject, text, body string) {
	kind := "账号"
	if admin {
		kind = "管理员账号"
	}
	subject = "Paircast " + kind + "已创建"
	text = "Paircast 已为你创建" + kind + "。\n\n" +
		"登录账号：" + email + "\n" +
		"初始密码：" + password + "\n\n" +
		"首次登录后需要先设置新密码。请妥善保管本邮件，改密后可删除。\n"
	body = `<div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;max-width:480px;margin:0 auto;padding:24px;color:#1f2329">` +
		`<h2 style="margin:0 0 16px;font-size:18px">Paircast</h2>` +
		`<p style="margin:0 0 12px">已为你创建` + kind + `。</p>` +
		`<p style="margin:0 0 4px">登录账号：` + html.EscapeString(email) + `</p>` +
		`<p style="margin:0 0 4px">初始密码：</p>` +
		`<p style="margin:0 0 16px;font-size:22px;font-weight:600;font-family:Menlo,Consolas,monospace;letter-spacing:2px">` + html.EscapeString(password) + `</p>` +
		`<p style="margin:0;color:#8f959e;font-size:13px">首次登录后需要先设置新密码。请妥善保管本邮件，改密后可删除。</p>` +
		`</div>`
	return
}
