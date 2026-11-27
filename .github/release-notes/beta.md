## AWDL 稳定性辅助：修复误判随航 | AWDL helper: no false Sidecar detection

修复用过随航后，即使没有连接随航屏幕，AWDL 稳定性辅助也一直跳过、不再关闭 awdl0 的问题。现在只在确实连接了随航屏幕时才保留 awdl0。
Fixes the AWDL helper always skipping and leaving awdl0 up after Sidecar had been used, even with no Sidecar display connected. It now keeps awdl0 up only while a Sidecar display is actually connected.

## 主机页通用退出 | Quit from the host page

支持在主机页退出桌面、退出大屏模式和退出其他正在运行的应用；大屏运行时，主按钮为“继续大屏模式”。
Supports quitting the desktop, Big Picture mode and any other running app from the host page; while Big Picture is running, the main button reads “Continue Big Picture Mode”.

## 关闭自动发现后不再查询局域网 | No local network queries when auto discovery is off

修复关闭“自动发现新主机”后仍然每 5 秒向局域网发送一次查询的问题：关闭后不再发送任何局域网查询，开启时主机页不在前台也会停止查询。
Fixes local network queries still being sent every 5 seconds after “Automatically Discover New Hosts” was turned off: with it off, no local network queries are sent, and with it on, queries also stop while the host list is out of sight.
