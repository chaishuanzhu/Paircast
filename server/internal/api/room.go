package api

import (
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/chaishuanzhu/Paircast/server/internal/watchroom"
)

// subtitleFetchPerMinute 是每个用户每分钟可下载的在线字幕数。
const subtitleFetchPerMinute = 10

// rateLimiter 是按用户的令牌桶（每分钟补满 perMinute 个）。
type rateLimiter struct {
	mu        sync.Mutex
	perMinute float64
	buckets   map[string]*bucket
	now       func() time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

func newRateLimiter(perMinute int) *rateLimiter {
	return &rateLimiter{perMinute: float64(perMinute), buckets: map[string]*bucket{}, now: time.Now}
}

func (l *rateLimiter) allow(uid string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if len(l.buckets) > 10000 {
		for k, b := range l.buckets {
			if now.Sub(b.last) > time.Minute {
				delete(l.buckets, k)
			}
		}
	}
	b, ok := l.buckets[uid]
	if !ok {
		b = &bucket{tokens: l.perMinute, last: now}
		l.buckets[uid] = b
	}
	b.tokens = min(l.perMinute, b.tokens+now.Sub(b.last).Minutes()*l.perMinute)
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

func formInt64(r *http.Request, key string) *int64 {
	raw := r.FormValue(key)
	if raw == "" {
		return nil
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return nil
	}
	return &v
}

func formString(r *http.Request, key string) *string {
	if _, present := r.Form[key]; !present {
		return nil
	}
	v := r.FormValue(key)
	return &v
}

// HandleRoomCreate 新建观影房间（同时建群），调用者为房主。movie_id 必须存在于媒体库。
// POST /room/create  (uid, token, movie_id)
func (s *Server) HandleRoomCreate(w http.ResponseWriter, r *http.Request) {
	uid, ok := s.roomAuth(w, r, http.MethodPost)
	if !ok {
		return
	}
	movieID := r.FormValue("movie_id")
	if movieID == "" {
		http.Error(w, "movie_id required", http.StatusBadRequest)
		return
	}
	if s.media != nil {
		if err := s.media.Exists(r.Context(), movieID); err != nil {
			writeMediaError(w, err)
			return
		}
	}
	room, err := s.rooms.Create(r.Context(), uid, movieID)
	if err != nil {
		writeMediaError(w, err)
		return
	}
	writeRoom(w, room)
}

// HandleRoomJoin 加入房间（同时入群）。
// POST /room/join  (uid, token, room_id)
func (s *Server) HandleRoomJoin(w http.ResponseWriter, r *http.Request) {
	uid, ok := s.roomAuth(w, r, http.MethodPost)
	if !ok {
		return
	}
	room, err := s.rooms.Join(r.Context(), uid, r.FormValue("room_id"))
	if err != nil {
		writeMediaError(w, err)
		return
	}
	writeRoom(w, room)
}

// HandleRoomLeave 离开房间：房主离开按加入顺序转让，最后一人离开结束房间。
// POST /room/leave  (uid, token, room_id, transfer_seq?)
func (s *Server) HandleRoomLeave(w http.ResponseWriter, r *http.Request) {
	uid, ok := s.roomAuth(w, r, http.MethodPost)
	if !ok {
		return
	}
	var seq int64
	if v := formInt64(r, "transfer_seq"); v != nil {
		seq = *v
	}
	room, err := s.rooms.Leave(r.Context(), uid, r.FormValue("room_id"), seq)
	if err != nil {
		writeMediaError(w, err)
		return
	}
	writeRoom(w, room)
}

// HandleRoomUpdate 修改房间（换片 / 转让房主 / 结束仅房主；序号只增不减）。换片时新 movie_id 必须存在。
// POST /room/update  (uid, token, room_id, movie_id?, host_uid?, host_transfer_seq?, last_applied_seq?, status=ended?, if_revision?)
func (s *Server) HandleRoomUpdate(w http.ResponseWriter, r *http.Request) {
	uid, ok := s.roomAuth(w, r, http.MethodPost)
	if !ok {
		return
	}
	movieID := formString(r, "movie_id")
	if movieID != nil && *movieID != "" && s.media != nil {
		if err := s.media.Exists(r.Context(), *movieID); err != nil {
			writeMediaError(w, err)
			return
		}
	}
	room, err := s.rooms.Update(r.Context(), uid, r.FormValue("room_id"), watchroom.Patch{
		MovieID:         movieID,
		HostUID:         formString(r, "host_uid"),
		HostTransferSeq: formInt64(r, "host_transfer_seq"),
		LastAppliedSeq:  formInt64(r, "last_applied_seq"),
		Ended:           r.FormValue("status") == watchroom.StatusEnded,
		IfRevision:      formInt64(r, "if_revision"),
	})
	if err != nil {
		writeMediaError(w, err)
		return
	}
	writeRoom(w, room)
}

// writeRoom 写房间响应，带上服务端时间（客户端据此推算播放快照的当前进度）。
func writeRoom(w http.ResponseWriter, room *watchroom.Room) {
	room.ServerTime = time.Now().UnixMilli()
	writeJSON(w, room)
}

// HandleRoomPlayback 保存房主的播放快照（新加入 / 重连的成员据此对齐）；不是房主返回 403，
// 影片不是当前影片或序号过旧时忽略。响应 {"applied": bool}。
// POST /room/playback  (token, room_id, movie_id, position_ms, paused, rate?, seq)
func (s *Server) HandleRoomPlayback(w http.ResponseWriter, r *http.Request) {
	uid, ok := s.roomAuth(w, r, http.MethodPost)
	if !ok {
		return
	}
	position, seq := formInt64(r, "position_ms"), formInt64(r, "seq")
	if position == nil || seq == nil || *position < 0 {
		http.Error(w, "position_ms and seq required", http.StatusBadRequest)
		return
	}
	paused, _ := strconv.ParseBool(r.FormValue("paused"))
	rate, _ := strconv.ParseFloat(r.FormValue("rate"), 64)
	applied, err := s.rooms.ReportPlayback(r.Context(), uid, r.FormValue("room_id"), watchroom.Playback{
		MovieID:    r.FormValue("movie_id"),
		PositionMs: *position,
		Paused:     paused,
		Rate:       rate,
		Seq:        *seq,
	})
	if err != nil {
		writeMediaError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"applied": applied})
}

// HandleRoomGet 返回房间状态（仅成员）。
// GET /room?uid=&token=&room_id=
func (s *Server) HandleRoomGet(w http.ResponseWriter, r *http.Request) {
	uid, ok := s.roomAuth(w, r, http.MethodGet)
	if !ok {
		return
	}
	room, err := s.rooms.Get(r.Context(), uid, r.URL.Query().Get("room_id"))
	if err != nil {
		writeMediaError(w, err)
		return
	}
	writeRoom(w, room)
}
