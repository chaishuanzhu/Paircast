# Design Tokens

Paircast iOS — designtoken.md format ([spec](https://designtoken.md/spec)).
Brand: co-watching cinema · primary = system blue · surfaces follow iOS grouped hierarchy.
Theme modes: `system` | `light` | `dark` (user preference; `system` defers to OS).

## Color Palette

### Primary (Paircast Blue)
- **50:** #E8F2FF
- **100:** #D1E6FF
- **200:** #A3CDFF
- **300:** #75B4FF
- **400:** #479BFF
- **500:** #007AFF
- **600:** #0066D6
- **700:** #0052AD
- **800:** #003D84
- **900:** #00295C

### Secondary (Cinema Ink)
- **50:** #F2F4F8
- **100:** #E1E6EF
- **200:** #C3CDDF
- **300:** #9AABC8
- **400:** #6B7FA3
- **500:** #4A5D7A
- **600:** #384860
- **700:** #283448
- **800:** #1A2333
- **900:** #0D121C

### Tertiary (Accent Sky)
- **50:** #F0F7FF
- **100:** #DCEBFF
- **200:** #B8D7FF
- **300:** #8BBCFF
- **400:** #5B9BFF
- **500:** #2E85FF
- **600:** #1F6AD6
- **700:** #1752AD
- **800:** #103C84
- **900:** #0A285C

### Neutral
#### Light
- **50:** #F7F7F8
- **100:** #F2F2F7
- **200:** #E5E5EA
- **300:** #D1D1D6
- **400:** #AEAEB2
- **500:** #8E8E93
- **600:** #636366
- **700:** #48484A
- **800:** #3A3A3C
- **900:** #1C1C1E

#### Dark
- **50:** #1C1C1E
- **100:** #2C2C2E
- **200:** #3A3A3C
- **300:** #48484A
- **400:** #636366
- **500:** #8E8E93
- **600:** #AEAEB2
- **700:** #C7C7CC
- **800:** #E5E5EA
- **900:** #F2F2F7

### Semantic Colors
- **Success:** #34C759 (Green)
- **Warning:** #FF9500 (Orange)
- **Error:** #FF3B30 (Red-600)
- **Info:** #007AFF (Primary-500)

### Semantic Surface Aliases

Light:
- **bg.grouped:** #F2F2F7 (neutral.100)
- **bg.elevated:** #FFFFFF
- **bg.watch:** #000000
- **bg.watchPanel:** #2C2C2E
- **label.primary:** #000000
- **label.secondary:** rgba(60,60,67,0.60)
- **label.tertiary:** rgba(60,60,67,0.30)
- **fill.brand:** #007AFF
- **separator:** rgba(60,60,67,0.29)

Dark:
- **bg.grouped:** #000000
- **bg.elevated:** #1C1C1E
- **bg.watch:** #000000
- **bg.watchPanel:** #2C2C2E
- **label.primary:** #FFFFFF
- **label.secondary:** rgba(235,235,245,0.60)
- **label.tertiary:** rgba(235,235,245,0.30)
- **fill.brand:** #0A84FF
- **separator:** rgba(84,84,88,0.65)

## Typography

### Font Stack
- **Primary:** SF Pro, SF Pro Display, system-ui, -apple-system, sans-serif
- **Mono:** SF Mono, Menlo, monospace

### Type Scale

| Name | Size | Weight | Line-Height | Spacing | Use |
|---------|-------|--------|-------------|----------|------------------|
| xs | 12px | 400 | 1.4 | 0.01em | Captions, metadata |
| sm | 13px | 400 | 1.4 | 0 | Secondary labels |
| base | 15px | 400 | 1.45 | 0 | Body / chat |
| lg | 17px | 400 | 1.35 | 0 | List rows, inputs |
| xl | 17px | 600 | 1.3 | -0.01em | Emphasized rows |
| 2xl | 22px | 700 | 1.2 | -0.02em | Nav large title start |
| 3xl | 28px | 700 | 1.15 | -0.02em | Library large title |
| 4xl | 34px | 700 | 1.1 | -0.03em | Login brand title |
| 5xl | 42px | 700 | 1.05 | -0.03em | Splash display |

## Spacing Scale

- **2xs:** 4px
- **xs:** 8px
- **sm:** 12px
- **md:** 16px
- **lg:** 24px
- **xl:** 32px
- **2xl:** 48px
- **3xl:** 64px
- **4xl:** 96px

## Border Radius

- **sm:** 8px
- **md:** 12px
- **lg:** 14px
- **xl:** 18px
- **full:** 9999px

## Elevation / Shadows

- **sm:** 0 1px 2px rgba(0,122,255,0.06)
- **md:** 0 4px 12px rgba(0,122,255,0.12)
- **lg:** 0 8px 24px rgba(0,0,0,0.16)
- **xl:** 0 16px 48px rgba(0,0,0,0.22)

## Component Tokens

### Buttons

Primary:
- background=color.primary.500
- text=#FFFFFF
- border=none
- radius=14px
- padding=14px 16px
- height=50px
- hover:background=color.primary.600
- focus:ring=0 0 0 3px rgba(0,122,255,0.28)
- disabled:opacity=0.5

Secondary:
- background=bg.elevated
- text=color.primary.500
- border=none
- radius=12px
- padding=12px 16px
- height=46px
- hover:background=neutral.100

Destructive:
- background=bg.elevated
- text=semantic.Error
- radius=12px
- padding=14px 16px

### Cards / Grouped Lists

- background=bg.elevated
- border=none
- radius=12px
- padding=0 (rows use 16px horizontal / 14px vertical)
- shadow=none (iOS grouped; flat)

### Inputs

- background=bg.elevated
- text=label.primary
- border=none (or 1px separator in forms)
- radius=12px
- padding=12px 14px
- focus:border=color.primary.500
- placeholder=label.tertiary

### Navigation

- background=bg.grouped (large title) / material
- height=large-title adaptive
- link:active=color.primary.500
- toolbar.icon=label.primary

### Theme Settings (product)

Options:
- **system** — Follow OS appearance (default)
- **light** — Force light semantic surfaces
- **dark** — Force dark semantic surfaces

Entry: 我的 → 设置分组 → 主题 → ThemeSettings (push)
Row trailing shows current mode label: 跟随系统 / 浅色 / 深色

## Visual Reference

> Applied feel for coding agents and design review.

- **Overall feel:** clean Apple HIG + cinema blue brand; not purple, not cream/terracotta
- **Primary** reads as iOS system blue for actions and brand mark
- **Surfaces** use grouped background + elevated white/ink cards
- **Typography** is SF Pro; large titles on library; splash uses display
- **Theme page** presents three selectable rows with checkmark; preview chips show light/dark swatches
- **Corners** are continuous rounded (radius.md–xl); shape language is soft iOS
