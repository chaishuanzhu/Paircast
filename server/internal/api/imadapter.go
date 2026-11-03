package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"

	"github.com/chaishuanzhu/GO-IM/pkg/imserver"
	"github.com/chaishuanzhu/Paircast/server/internal/watchroom"
)

// IMGroups 用服务端 API 实现 watchroom.Groups。
type IMGroups struct{ C *imserver.Client }

// Create 实现 watchroom.Groups。
func (g IMGroups) Create(ctx context.Context, name, ownerUID string) (string, error) {
	grp, err := g.C.CreateGroup(ctx, name, imserver.UID(ownerUID), nil)
	if err != nil {
		return "", err
	}
	return grp.ID, nil
}

// Join 实现 watchroom.Groups。
func (g IMGroups) Join(ctx context.Context, groupID, uid string) error {
	_, err := g.C.AddGroupMembers(ctx, groupID, []imserver.UserRef{imserver.UID(uid)})
	if imserver.IsNotFound(err) {
		return watchroom.ErrEnded
	}
	return err
}

// Leave 实现 watchroom.Groups。
func (g IMGroups) Leave(ctx context.Context, groupID, uid string) error {
	_, err := g.C.RemoveGroupMembers(ctx, groupID, []imserver.UserRef{imserver.UID(uid)})
	if imserver.IsNotFound(err) {
		return nil
	}
	return err
}

// Dismiss 实现 watchroom.Groups。
func (g IMGroups) Dismiss(ctx context.Context, groupID string) error {
	err := g.C.DismissGroup(ctx, groupID)
	if imserver.IsNotFound(err) {
		return nil
	}
	return err
}

// IMNotifier 用服务端 API 的瞬时信令推送房间变化（类型 paircast.room_updated）。
type IMNotifier struct{ C *imserver.Client }

// RoomUpdated 实现 watchroom.Notifier。
func (n IMNotifier) RoomUpdated(ctx context.Context, actorUID string, room *watchroom.Room) {
	from := imserver.UID(actorUID)
	err := n.C.SendSignal(ctx, imserver.Signal{
		From:    &from,
		GroupID: room.GroupID,
		Type:    RoomUpdatedSignal,
		Data:    map[string]any{"group_id": room.GroupID, "room": room},
	})
	if err != nil {
		log.Printf("[paircast] room_updated signal for %s: %v", room.ID, err)
	}
}

// WebhookHandler 接收 IM webhook，把 IM 侧的退群 / 解散同步到房间。处理失败返回 500，IM 会重试。
func WebhookHandler(rooms *watchroom.Service, secret string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ev, err := imserver.ParseWebhook(r, secret)
		if err != nil {
			http.Error(w, "bad signature", http.StatusUnauthorized)
			return
		}
		var data struct {
			GroupID string `json:"group_id"`
			UID     string `json:"uid"`
		}
		json.Unmarshal(ev.Data, &data)
		switch ev.Type {
		case imserver.EventGroupMemberLeft:
			err = rooms.GroupMemberLeft(r.Context(), data.GroupID, data.UID)
		case imserver.EventGroupDismissed:
			err = rooms.GroupDismissed(r.Context(), data.GroupID)
		}
		if err != nil {
			log.Printf("[paircast] webhook %s %s: %v", ev.Type, ev.ID, err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
