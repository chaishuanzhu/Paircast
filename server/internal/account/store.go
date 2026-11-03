package account

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"sync"

	"github.com/go-sql-driver/mysql"
)

// MemoryStore 是进程内实现（MySQL 未启用或测试时）。
type MemoryStore struct {
	mu     sync.Mutex
	users  map[int64]*User
	nextID int64
}

// NewMemoryStore 创建进程内存储。
func NewMemoryStore() *MemoryStore {
	return &MemoryStore{users: map[int64]*User{}}
}

// Create 实现 Store。
func (s *MemoryStore) Create(_ context.Context, u *User) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, e := range s.users {
		if e.Email == u.Email {
			return ErrEmailTaken
		}
	}
	s.nextID++
	u.ID = s.nextID
	s.users[u.ID] = u.clone()
	return nil
}

// Get 实现 Store。
func (s *MemoryStore) Get(_ context.Context, id int64) (*User, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if u, ok := s.users[id]; ok {
		return u.clone(), nil
	}
	return nil, ErrNotFound
}

func (s *MemoryStore) find(match func(*User) bool) (*User, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, u := range s.users {
		if match(u) {
			return u.clone(), nil
		}
	}
	return nil, ErrNotFound
}

// GetByEmail 实现 Store。
func (s *MemoryStore) GetByEmail(_ context.Context, email string) (*User, error) {
	return s.find(func(u *User) bool { return u.Email == email })
}

// GetByIMUID 实现 Store。
func (s *MemoryStore) GetByIMUID(_ context.Context, imUID string) (*User, error) {
	if imUID == "" {
		return nil, ErrNotFound
	}
	return s.find(func(u *User) bool { return u.IMUID == imUID })
}

// List 实现 Store。
func (s *MemoryStore) List(_ context.Context, offset, limit int) ([]*User, int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	all := make([]*User, 0, len(s.users))
	for _, u := range s.users {
		all = append(all, u.clone())
	}
	sort.Slice(all, func(i, j int) bool { return all[i].ID > all[j].ID })
	total := len(all)
	if offset > total {
		offset = total
	}
	end := min(offset+limit, total)
	return all[offset:end], total, nil
}

// Update 实现 Store。
func (s *MemoryStore) Update(_ context.Context, id int64, fn func(*User) error) (*User, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[id]
	if !ok {
		return nil, ErrNotFound
	}
	next := u.clone()
	if err := fn(next); err != nil {
		return nil, err
	}
	s.users[id] = next
	return next.clone(), nil
}

// Delete 实现 Store。
func (s *MemoryStore) Delete(_ context.Context, id int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.users, id)
	return nil
}

// MySQLStore 把账号存在 paircast_users 表。
type MySQLStore struct{ db *sql.DB }

// NewMySQLStore 建表（若不存在）并返回存储。
func NewMySQLStore(db *sql.DB) (*MySQLStore, error) {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS paircast_users (
			id                   BIGINT       NOT NULL AUTO_INCREMENT,
			email                VARCHAR(254) NOT NULL,
			password_hash        VARCHAR(100) NOT NULL,
			nickname             VARCHAR(64)  NOT NULL DEFAULT '',
			avatar_file_id       BIGINT       NOT NULL DEFAULT 0,
			role                 VARCHAR(16)  NOT NULL DEFAULT 'user',
			disabled             TINYINT(1)   NOT NULL DEFAULT 0,
			must_change_password TINYINT(1)   NOT NULL DEFAULT 0,
			token_version        BIGINT       NOT NULL DEFAULT 0,
			im_uid               VARCHAR(64)  NULL,
			created_at           BIGINT       NOT NULL,
			updated_at           BIGINT       NOT NULL,
			PRIMARY KEY (id),
			UNIQUE KEY uk_email (email),
			UNIQUE KEY uk_im_uid (im_uid)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`)
	if err != nil {
		return nil, fmt.Errorf("create paircast_users: %w", err)
	}
	return &MySQLStore{db: db}, nil
}

const userColumns = `id, email, password_hash, nickname, avatar_file_id, role, disabled, must_change_password,
	token_version, COALESCE(im_uid, ''), created_at, updated_at`

type scanner interface{ Scan(dest ...any) error }

func scanUser(row scanner) (*User, error) {
	u := &User{}
	err := row.Scan(&u.ID, &u.Email, &u.PasswordHash, &u.Nickname, &u.AvatarFileID, &u.Role, &u.Disabled,
		&u.MustChangePassword, &u.TokenVersion, &u.IMUID, &u.CreatedAt, &u.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return u, nil
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// Create 实现 Store。
func (s *MySQLStore) Create(ctx context.Context, u *User) error {
	res, err := s.db.ExecContext(ctx, `INSERT INTO paircast_users
		(email, password_hash, nickname, avatar_file_id, role, disabled, must_change_password, token_version, im_uid, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		u.Email, u.PasswordHash, u.Nickname, u.AvatarFileID, u.Role, u.Disabled, u.MustChangePassword,
		u.TokenVersion, nullable(u.IMUID), u.CreatedAt, u.UpdatedAt)
	if isDuplicate(err) {
		return ErrEmailTaken
	}
	if err != nil {
		return fmt.Errorf("insert user: %w", err)
	}
	u.ID, err = res.LastInsertId()
	return err
}

// Get 实现 Store。
func (s *MySQLStore) Get(ctx context.Context, id int64) (*User, error) {
	return scanUser(s.db.QueryRowContext(ctx, `SELECT `+userColumns+` FROM paircast_users WHERE id = ?`, id))
}

// GetByEmail 实现 Store。
func (s *MySQLStore) GetByEmail(ctx context.Context, email string) (*User, error) {
	return scanUser(s.db.QueryRowContext(ctx, `SELECT `+userColumns+` FROM paircast_users WHERE email = ?`, email))
}

// GetByIMUID 实现 Store。
func (s *MySQLStore) GetByIMUID(ctx context.Context, imUID string) (*User, error) {
	if imUID == "" {
		return nil, ErrNotFound
	}
	return scanUser(s.db.QueryRowContext(ctx, `SELECT `+userColumns+` FROM paircast_users WHERE im_uid = ?`, imUID))
}

// List 实现 Store。
func (s *MySQLStore) List(ctx context.Context, offset, limit int) ([]*User, int, error) {
	var total int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM paircast_users`).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+userColumns+` FROM paircast_users ORDER BY id DESC LIMIT ? OFFSET ?`, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []*User
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, u)
	}
	return out, total, rows.Err()
}

// Update 实现 Store。
func (s *MySQLStore) Update(ctx context.Context, id int64, fn func(*User) error) (*User, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	u, err := scanUser(tx.QueryRowContext(ctx, `SELECT `+userColumns+` FROM paircast_users WHERE id = ? FOR UPDATE`, id))
	if err != nil {
		return nil, err
	}
	if err := fn(u); err != nil {
		return nil, err
	}
	_, err = tx.ExecContext(ctx, `UPDATE paircast_users SET email = ?, password_hash = ?, nickname = ?, avatar_file_id = ?,
		role = ?, disabled = ?, must_change_password = ?, token_version = ?, im_uid = ?, updated_at = ? WHERE id = ?`,
		u.Email, u.PasswordHash, u.Nickname, u.AvatarFileID, u.Role, u.Disabled, u.MustChangePassword,
		u.TokenVersion, nullable(u.IMUID), u.UpdatedAt, id)
	if isDuplicate(err) {
		return nil, ErrEmailTaken
	}
	if err != nil {
		return nil, fmt.Errorf("update user: %w", err)
	}
	return u, tx.Commit()
}

// Delete 实现 Store。
func (s *MySQLStore) Delete(ctx context.Context, id int64) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM paircast_users WHERE id = ?`, id)
	return err
}

func isDuplicate(err error) bool {
	var me *mysql.MySQLError
	return errors.As(err, &me) && me.Number == 1062
}
