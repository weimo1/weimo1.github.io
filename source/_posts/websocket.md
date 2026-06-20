---
title: websocket
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "网络编程"]
publish: true
---

# WebSocket 协议

## 概述

WebSocket 是一种在单个 TCP 连接上实现全双工通信的应用层协议，由 RFC 6455 正式定义。它解决了传统 HTTP 协议无法实现服务端主动推送的问题。在 WebSocket 出现之前，开发者只能通过轮询（Polling）或长轮询（Long Polling）模拟实时通信，效率和实时性都受到限制。

## 握手过程

WebSocket 通过 HTTP Upgrade 机制完成协议升级：客户端发送 GET 请求，包含 Upgrade: websocket、Connection: Upgrade 头部，以及 Sec-WebSocket-Key（随机 Base64 编码的 16 字节值）。服务端验证请求后返回 101 Switching Protocols 状态码，附带 Sec-WebSocket-Accept 头部（对客户端 Key 进行 SHA-1 摘要后 Base64 编码）。握手完成后，连接从 HTTP 协议无缝升级为 WebSocket 协议，TCP 连接保持不断开。

## 帧格式

WebSocket 以帧（frame）为基本通信单位。帧格式包括：FIN 位标识是否为消息的最后一帧；Opcode 标识帧类型（0x1 文本、0x2 二进制、0x8 关闭、0x9 Ping、0xA Pong）；MASK 位标识是否掩码（客户端发送必须掩码）；Payload Length 标识载荷长度（7/16/63 位三种编码）；Masking Key（32 位，仅在 MASK=1 时存在）；Payload Data 为实际数据内容。

## 控制帧

关闭帧（Opcode 0x8）包含状态码和关闭原因，双方收到关闭帧后主动关闭 TCP 连接。Ping 帧（Opcode 0x9）用于连接保活和延迟检测，接收方必须回复 Pong 帧。Pong 帧（Opcode 0xA）响应 Ping 帧，也可主动发送表示连接仍存活。

## 应用场景

WebSocket 广泛应用于即时通讯系统（微信网页版、Slack 等），实现消息的实时收发。实时数据推送场景（股票行情、体育比分、通知推送）中替代了传统轮询方案。在线协作编辑（Google Docs 等）使用 WebSocket 同步编辑操作。多人游戏通过 WebSocket 实现低延迟的实时同步。此外，WebSocket 还用于直播弹幕、物联网设备通信等领域。

## 安全性

WebSocket 支持 wss 方案（WebSocket over TLS），通过证书机制加密通信内容。服务端可通过 Origin 头部验证请求来源，防止跨站 WebSocket 劫持攻击。合理设置心跳间隔和超时时间可防止连接泄漏。

WebSocket 协议已经成为现代 Web 实时通信的标准方案，被各大浏览器广泛支持。配合消息队列和分布式架构，WebSocket 可以支撑千万级并发的实时通信系统。