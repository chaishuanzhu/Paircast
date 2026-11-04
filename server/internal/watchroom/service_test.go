package watchroom

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

type fakeGroups struct {
	members map[string][]string
	n       int
}

func (g *fakeGroups) Create(_ context.Context, name string, owner string) (string, error) {
	if n := utf8.RuneCountInString(strings.TrimSpace(name)); n == 0 || n > 32 {
		return "", fmt.Errorf("group name %q: must be 1-32 characters", name)
	}
	g.n++
	id := fmt.Sprintf("g_%d", g.n)
	g.members[id] = []string{owner}
	return id, nil
}

func (g *fakeGroups) Join(_ context.Context, id, uid string) error {
	m, ok := g.members[id]
	if !ok {
		return ErrEnded
	}
	if !slices.Contains(m, uid) {
		g.members[id] = append(m, uid)
	}
	return nil
}

func (g *fakeGroups) Leave(_ context.Context, id, uid string) error {
	g.members[id] = slices.DeleteFunc(g.members[id], func(m string) bool { return m == uid })
	return nil
}

func (g *fakeGroups) Dismiss(_ context.Context, id string) error {
	delete(g.members, id)
	return nil
}

func (g *fakeGroups) Members(_ context.Context, id string) ([]string, error) {
	m, ok := g.members[id]
	if !ok {
		return nil, ErrEnded
	}
	return slices.Clone(m), nil
}

type recorder struct{ rooms []*Room }

func (r *recorder) RoomUpdated(_ context.Context, _ string, room *Room) {
	r.rooms = append(r.rooms, room)
}

func newService() (*Service, *fakeGroups, *recorder) {
	groups := &fakeGroups{members: map[string][]string{}}
	rec := &recorder{}
	n := 0
	return NewService(NewMemoryStore(), groups, rec, func() string { n++; return fmt.Sprintf("room-%d", n) }), groups, rec
}

func TestCreateJoinAndNotify(t *testing.T) {
	ctx := context.Background()
	svc, groups, rec := newService()
	room, err := svc.Create(ctx, "alice", "oss:films/a.mp4")
	if err != nil {
		t.Fatal(err)
	}
	if room.HostUID != "alice" || room.GroupID != "g_1" || room.Status != StatusActive {
		t.Fatalf("room = %+v", room)
	}
	joined, err := svc.Join(ctx, "bob", "ROOM-1")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(joined.Members, []string{"alice", "bob"}) || joined.Revision != 2 {
		t.Fatalf("joined = %+v", joined)
	}
	if !slices.Contains(groups.members["g_1"], "bob") || len(rec.rooms) != 1 {
		t.Errorf("group/notify not updated: %v %d", groups.members, len(rec.rooms))
	}
	again, _ := svc.Join(ctx, "bob", "room-1")
	if len(again.Members) != 2 {
		t.Errorf("rejoin duplicated member: %v", again.Members)
	}
}

func TestHostLeaveTransfersByJoinOrderAndLastLeaveEnds(t *testing.T) {
	ctx := context.Background()
	svc, groups, _ := newService()
	svc.Create(ctx, "alice", "m")
	svc.Join(ctx, "bob", "room-1")
	svc.Join(ctx, "carol", "room-1")

	room, err := svc.Leave(ctx, "alice", "room-1", 500)
	if err != nil {
		t.Fatal(err)
	}
	if room.HostUID != "bob" || room.HostTransferSeq != 500 || room.Status != StatusActive {
		t.Fatalf("after host leave: %+v", room)
	}
	if slices.Contains(groups.members["g_1"], "alice") {
		t.Error("alice should have left the group")
	}
	svc.Leave(ctx, "carol", "room-1", 0)
	room, _ = svc.Leave(ctx, "bob", "room-1", 0)
	if room.Status != StatusEnded || len(room.Members) != 0 {
		t.Fatalf("last leave: %+v", room)
	}
	if _, err := svc.Join(ctx, "dave", "room-1"); !errors.Is(err, ErrEnded) {
		t.Errorf("join ended room: %v", err)
	}
}

func TestUpdateAuthorization(t *testing.T) {
	ctx := context.Background()
	svc, _, _ := newService()
	svc.Create(ctx, "alice", "m1")
	svc.Join(ctx, "bob", "room-1")
	m2 := "m2"
	if _, err := svc.Update(ctx, "bob", "room-1", Patch{MovieID: &m2}); !errors.Is(err, ErrNotHost) {
		t.Errorf("member movie change: %v", err)
	}
	if _, err := svc.Update(ctx, "eve", "room-1", Patch{}); !errors.Is(err, ErrNotMember) {
		t.Errorf("outsider update: %v", err)
	}
	svc.SetSubtitle(ctx, "alice", "room-1", "blob:x.srt", "ZH")
	room, err := svc.Update(ctx, "alice", "room-1", Patch{MovieID: &m2})
	if err != nil || room.MovieID != "m2" || room.SubtitleRef != "" {
		t.Fatalf("host movie change: %+v %v", room, err)
	}
	stranger := "eve"
	if _, err := svc.Update(ctx, "alice", "room-1", Patch{HostUID: &stranger}); !errors.Is(err, ErrInvalidHost) {
		t.Errorf("transfer to outsider: %v", err)
	}
	bob := "bob"
	seq := int64(42)
	room, _ = svc.Update(ctx, "alice", "room-1", Patch{HostUID: &bob, HostTransferSeq: &seq})
	if room.HostUID != "bob" || room.HostTransferSeq != 42 {
		t.Fatalf("transfer: %+v", room)
	}
	lower := int64(1)
	room, _ = svc.Update(ctx, "bob", "room-1", Patch{HostTransferSeq: &lower})
	if room.HostTransferSeq != 42 {
		t.Errorf("seq regressed: %d", room.HostTransferSeq)
	}
	stale := room.Revision - 1
	if _, err := svc.Update(ctx, "bob", "room-1", Patch{IfRevision: &stale}); !errors.Is(err, ErrConflict) {
		t.Errorf("stale revision: %v", err)
	}
	if _, err := svc.Get(ctx, "eve", "room-1"); !errors.Is(err, ErrNotMember) {
		t.Errorf("outsider get: %v", err)
	}
}

func TestRequireHost(t *testing.T) {
	ctx := context.Background()
	svc, _, _ := newService()
	svc.Create(ctx, "alice", "m")
	svc.Join(ctx, "bob", "room-1")
	if _, err := svc.RequireHost(ctx, "bob", "room-1"); !errors.Is(err, ErrNotHost) {
		t.Errorf("member as host: %v", err)
	}
	if _, err := svc.RequireHost(ctx, "alice", "room-1"); err != nil {
		t.Errorf("host: %v", err)
	}
}

func TestWebhookSyncAndJanitorDismiss(t *testing.T) {
	ctx := context.Background()
	svc, groups, rec := newService()
	room, _ := svc.Create(ctx, "alice", "m")
	svc.Join(ctx, "bob", room.ID)

	if err := svc.GroupMemberLeft(ctx, room.GroupID, "alice"); err != nil {
		t.Fatal(err)
	}
	got, _ := svc.Get(ctx, "bob", room.ID)
	if got.IsMember("alice") || got.HostUID != "bob" {
		t.Fatalf("after alice left the group: %+v", got)
	}
	if last := rec.rooms[len(rec.rooms)-1]; last.IsMember("alice") {
		t.Fatal("no room_updated after webhook leave")
	}
	if err := svc.GroupMemberLeft(ctx, "g_unknown", "x"); err != nil {
		t.Fatal(err)
	}

	if err := svc.GroupDismissed(ctx, room.GroupID); err != nil {
		t.Fatal(err)
	}
	if got, _ := svc.Get(ctx, "bob", room.ID); got.Status != StatusEnded {
		t.Fatalf("after dismiss: %+v", got)
	}

	other, _ := svc.Create(ctx, "carol", "m")
	svc.now = func() time.Time { return time.Now().Add(time.Hour) }
	svc.cleanup(ctx, time.Minute)
	if _, ok := groups.members[other.GroupID]; ok {
		t.Fatal("janitor did not dismiss the stale room's group")
	}
	if _, err := svc.Get(ctx, "carol", other.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stale room not deleted: %v", err)
	}
}

func TestCreateWithRandomIDFitsGroupNameLimit(t *testing.T) {
	groups := &fakeGroups{members: map[string][]string{}}
	svc := NewService(NewMemoryStore(), groups, nil, NewRandomID)
	room, err := svc.Create(context.Background(), "u1", "oss:a.mp4")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if room.GroupID == "" {
		t.Fatal("room has no group")
	}
}

func TestReconcile(t *testing.T) {
	ctx := context.Background()
	svc, groups, _ := newService()
	room, _ := svc.Create(ctx, "alice", "m")
	if _, err := svc.Join(ctx, "bob", room.ID); err != nil {
		t.Fatal(err)
	}

	// 丢失的 member_left：bob 已不在聊天室，对账后移出房间。
	groups.members[room.GroupID] = []string{"alice"}
	svc.reconcile(ctx)
	if got, _ := svc.Get(ctx, "alice", room.ID); got.IsMember("bob") {
		t.Fatal("bob should be removed from the room")
	}

	// 失败的退群：carol 在聊天室、不在房间，第二轮才移出（第一轮可能是进房进行到一半）。
	groups.members[room.GroupID] = append(groups.members[room.GroupID], "carol")
	svc.reconcile(ctx)
	if !slices.Contains(groups.members[room.GroupID], "carol") {
		t.Fatal("carol removed after a single pass")
	}
	svc.reconcile(ctx)
	if slices.Contains(groups.members[room.GroupID], "carol") {
		t.Fatal("carol should be removed from the chatroom on the second pass")
	}

	// 丢失的 dismissed：聊天室不存在，房间结束。
	delete(groups.members, room.GroupID)
	svc.reconcile(ctx)
	if got, _ := svc.Get(ctx, "alice", room.ID); got.Status != StatusEnded {
		t.Fatalf("room status %s, want ended", got.Status)
	}
}

func TestReportPlayback(t *testing.T) {
	ctx := context.Background()
	svc, _, _ := newService()
	room, _ := svc.Create(ctx, "alice", "m")
	svc.Join(ctx, "bob", room.ID)

	if ok, err := svc.ReportPlayback(ctx, "alice", room.ID, Playback{MovieID: "m", PositionMs: 5000, Seq: 10}); !ok || err != nil {
		t.Fatalf("host report: %v %v", ok, err)
	}
	if _, err := svc.ReportPlayback(ctx, "bob", room.ID, Playback{MovieID: "m", Seq: 11}); !errors.Is(err, ErrNotHost) {
		t.Fatalf("member report: %v", err)
	}
	if ok, _ := svc.ReportPlayback(ctx, "alice", room.ID, Playback{MovieID: "m", PositionMs: 1, Seq: 9}); ok {
		t.Fatal("older seq applied")
	}
	if ok, _ := svc.ReportPlayback(ctx, "alice", room.ID, Playback{MovieID: "other", Seq: 12}); ok {
		t.Fatal("other movie applied")
	}
	got, _ := svc.Get(ctx, "bob", room.ID)
	if got.Playback == nil || got.Playback.PositionMs != 5000 || got.Playback.Rate != 1 || got.Revision != room.Revision+1 {
		t.Fatalf("playback %+v revision %d (join only should bump it)", got.Playback, got.Revision)
	}

	next := "n"
	if _, err := svc.Update(ctx, "alice", room.ID, Patch{MovieID: &next}); err != nil {
		t.Fatal(err)
	}
	if got, _ := svc.Get(ctx, "bob", room.ID); got.Playback != nil {
		t.Fatal("movie change should clear the playback snapshot")
	}
}
