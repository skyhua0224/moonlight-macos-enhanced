# Deck gamepad walk

Scripted-pad harness for the Deck interface (macOS Enhanced). `walks.sh <light|dark>` runs every row of the table
below on the harness Mac and prints `N checks, M failed` per walk; it needs a harness build (`MLC_CONCEPT_HARNESS`)
of the tree under `$PAD_SANDBOX/dd-padh` and runs under the lock shared with every other macOS build and run.

- `MLC_PAD` (ConceptHarness.m, `+runPadScript`) presses buttons through ControllerNavigation's own 60 Hz poll
  (`MLControllerInject`, held two polls, so the real edge/repeat code runs), or through the raw DualSense mapping
  (`R<button>`, `MLControllerInjectRaw` → `DS5UIButtons.h`), and logs `PAD <n> <token> <focus state>`.
- `expect=<key>` / `expectstate=<text>` are the checks; `shot=<name>` is a window-server composite (window, ring, legend).
- `padrun.sh` runs on the Mac, `padwalk.sh` on the build host (ssh + flock), `walks.sh` is the suite.
- `tests/ds5-ui-pad/run.sh` tests the raw DualSense button/hat/stick mapping against the core parser (no Apple frameworks).

## Buttons

| Button | Deck main window | Sheet, alert, popover | Menu list |
|---|---|---|---|
| D-pad, left stick | spatial focus on the page, repeats; never into the computer list | same | up / down, left = back a level |
| A | activate (open, connect, press, open menu) | same | choose |
| B | cancel a pending connection / pairing / close an icon picker, else nothing (the page is the top level) | close (its Cancel button, else dismiss) | close |
| Menu (≡) | context menu of the focused control (app menu, computer menu), else of the region around it, else the page menu (添加电脑, 清理旧记录) | – | – |
| LB / RB | previous / next computer, a pill names it ("name n/m"), the focus stays on the page | – | – |
| LT / RT (L2 / R2) | previous / next section of the page (hero, 最近使用, 固定, 应用 …): the jump lands on the section's first app tile (the hero: its primary button), or where the focus last was in it; no wrap, LT in the first section scrolls the page to the top | – | – |
| Y | Settings | – | – |
| X | 自定义主页 | – | – |
| View | search | – | – |
| right stick | scrolls the page | | |

Settings: LB / RB pick the column, LT / RT turn pages of the list; B goes back a column, then closes the window.

The focus ring (dark hairline + white halo + accent colour, a child window: nothing in the page moves) shows only while the
pad was the last input; the first press after the pointer was used only shows it again. Glyphs come from GameController
(Xbox / PlayStation); a DualSense that only the raw HID bridge sees counts as PlayStation.

## Audit: what a pad reaches (before → after)

Before = reading of ControllerNavigation.m and the Deck views at 505ea4f9: in the main window the pad sent Tab / arrow /
space keys (no focus ring, the ring and the anchors only ran in the Settings window); sheets, alerts and popovers of the main
window were ignored; `.controllerFocusTarget` anchors existed on tiles, connect and 添加电脑 but nothing consumed them there.
After = walked by `walks.sh` (walk name in brackets) unless it says otherwise.

| View | Control | Before | After |
|---|---|---|---|
| Sidebar (DeckSidebarView) | the computer list (在线 / 附近未配对 / 离线 / 旧记录) | focus ring, selection follows focus | **out of the focus graph**: D-pad, stick and B never enter it (the graph filter drops it whatever column the navigator is in); computers switch with LB / RB only [sidebar, switch] |
| | 搜索电脑 field | reached, A / View open the pad keyboard | View raises the keyboard on it, the focus stays on the page |
| | row context menu: 更改图标, 唤醒, 重命名, 详情, 移除 | Menu button on the row | not reachable from the list any more: 更改图标 = the host icon on the page (A), the rest = the page's ⋯ menu [home, unpaired] |
| | 选择图片… (system file panel) | **not reachable**: NSOpenPanel is a system remote panel | same |
| | 清理旧记录, 添加电脑 | reached, A | page menu: Menu where nothing under the focus has a menu of its own [pagemenu, addhost] |
| Home page (DeckComputerView, DeckHeroHeader, DeckConnectBar) | 连接 / 继续 / 唤醒 / 配对 (primary) | anchor, unused | focus lands on it when the page is entered [home, unpaired, offline] |
| | 退出应用, 连接桌面, 大屏模式 | no | reached [home] |
| | 串流设置 (⚙) | no | reached [home]; A opens the settings window (not walked) |
| | 更多 (⋯) menu | popped at the pointer | A lists it in the controller menu [home] |
| | 正在连接… / 取消 | no | B cancels the pending launch, and also while the stream window only shows its startup overlay (it is closed, which cancels) [connect]; A on 取消 too |
| | PIN panel, 取消配对 | no | B cancels pairing [unpaired] |
| | host icon (edit) | no | A opens the icon picker popover; reached [unpaired] |
| | 线路 / 网卡 chips, Foundation Sunshine label | no | anchored (route chips choose the path), reached while walking up [home]; not activated |
| | 应用 shelves: title › (expand), landscape / poster / big-screen / continue tiles | tiles anchored, unused | reached, A opens, Menu = app menu, page scrolls with focus [home] |
| | tile ▶ and ⋯ mini buttons | pointer | left out on purpose (A and Menu do the same) |
| | tile size slider, 自动 | no | slider reached, D-pad left/right adjusts [home, offline] |
| | tiles of an offline computer | pointer cannot click them | pad skips them too |
| | 地址 rows: copy, 测试, default radio, ⋯ menu, edit field + type | no | reached [unpaired, offline]; the type picker lists in the controller menu (added, not walked) |
| | 添加连接方式…, 自动 radio | no | reached [unpaired, offline] |
| | page scroll | scroll wheel | right stick, and D-pad pages the list at its end |
| Sheets and alerts | 连接详情 sheet | ignored | focus on 关闭, B closes, focus returns to the control that opened it; no walk (the harness host has no way to open it by pad now that the list is out) |
| | 添加电脑 sheet (field, 配对, 取消, 添加) | ignored | reached, keyboard, B closes, focus returns to 添加电脑 [addhost] |
| | NSAlert sheets (移除, 配对, …) | ignored | buttons reached, B = Cancel [addhost, scripted alert]; the real 移除 alert does not show in the harness (no host window), same code path |
| | 编辑连接 sheet (AppKit form) | ignored | same collector as the sheets above; not walked |
| 自定义主页 popover (X) | style cards, size slider, switch, three segmented rows | no | reached [customize] |
| | section checkboxes, reorder handles | pointer drag | handle: A lists 上移 / 下移 [customize]; checkbox is left of the handle |
| | 恢复默认, B | no | B closes the popover, focus returns to the page [customize] |
| Toolbar | 自定义主页, search, 添加 | – | X, View and the sidebar button; sidebar toggle and back arrow have no pad action |
| All | focus returns | – | after a sheet, a popover, a menu, a page rebuild and a window leaving and coming back [addhost, customize, switch] |
| | LT / RT jump between sections | no | [sections]; raw DualSense (analog trigger, pressed from 0.60 of the travel, released below 0.35, edge only, no repeat) [sectionsraw]; windows without sections (Settings) turn a page of controls: the control about a page further, at the end the last one [settingspage] |
| | LB / RB switch computers | no | pill with the name and n/m, also at either end of the list (the selection stays); the focus is placed on the new page's primary button [switch] |
| | window opened from a control (settings via Y or the ⚙ button) | focus lost or left in the computer list | the place is remembered when the window takes the pad, comes back to the opener, else the page's primary button; a button held through the change stays silent until released [settings, settingsgear] |
| | ring only while the pad is in use | – | pointer hides it, the first press shows it again [presence] |
| | DualSense through the raw HID bridge | – | same walk through the mapping [raw]; real device not available here |
| Not Deck-specific | variant B cards (⋯ menu), first-run page, FS banner buttons | | anchored in code (controllerButtonStyle / controllerFocusMenu), not walked |
