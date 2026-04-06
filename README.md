# Copilot Chat for iOS

把 GitHub Copilot 的聊天功能帶到 iOS。純 SwiftUI，不依賴第三方框架。

## 功能

- GitHub Copilot Chat（OpenAI-compatible API）
- Streaming response，即時顯示回應
- Markdown 渲染（標題、粗體、斜體、程式碼區塊、列表、引用）
- MCP（Model Context Protocol）remote HTTP server 支援
- 多 MCP server 管理
- 模型選擇（claude-sonnet-4-6、gpt-4o 等）
- 深色模式支援

## 需求

- iOS 26+
- Xcode 26+
- GitHub 帳號（有 Copilot 權限）

## 安裝步驟

### 1. 開啟專案

```bash
open CopilotChat.xcodeproj
```

### 2. 設定簽名

1. 在 Xcode 中選擇 **CopilotChat** target
2. 到 **Signing & Capabilities**
3. 選擇你的 **Development Team**（Personal Team 即可）
4. 如果 Bundle Identifier 衝突，改成唯一的（例如 `com.yourname.copilotchat`）

### 3. 安裝到裝置

1. 用 USB 連接 iPhone/iPad
2. 在 Xcode 上方選擇你的裝置
3. 按 **Cmd + R** 編譯並安裝
4. 首次安裝需要到裝置上：**設定 → 一般 → VPN 與裝置管理** → 信任開發者

## 使用方式

### 登入 GitHub

1. 開啟 App → 點右上角齒輪 → **Settings**
2. 點 **Sign in with GitHub**
3. App 會顯示一組驗證碼和 GitHub 連結
4. 在瀏覽器開啟連結，輸入驗證碼
5. 授權後 App 會自動完成登入

### 聊天

登入後直接在輸入框打字，按送出即可。預設模型為 `claude-sonnet-4-6`，可在設定中更改。

### 設定 MCP Server

1. 到 **Settings → MCP Servers → Add MCP Server**
2. 填入：
   - **Name**: 顯示名稱（例如 `memory-connect`）
   - **URL**: Server endpoint（例如 `https://your-worker.workers.dev/mcp`）
   - **Headers**: 認證 header，每行一個（例如 `Authorization: Bearer your-token`）
3. 儲存後 App 會自動連線並載入 tools

MCP tools 會自動注入到 Copilot API 的 `tools` 參數中。當 AI 回應包含 tool call 時，App 會自動透過 MCP server 執行並回傳結果。

## 認證流程

本 App 使用 GitHub Device Flow OAuth：

1. 向 GitHub 請求 device code
2. 使用者在瀏覽器授權
3. App 取得 OAuth token
4. 直接用 OAuth token 作為 Bearer token 呼叫 `api.githubcopilot.com`

不需要建立自己的 GitHub OAuth App，使用的是 Copilot 公開的 Client ID。

## 技術架構

- **Swift 6** strict concurrency
- **@Observable** macro（Observation framework）
- **URLSession async/await** + `bytes(for:)` SSE streaming
- **Keychain** 安全儲存 token
- **MCP Streamable HTTP** transport（JSON-RPC over HTTP）
- **XcodeGen** 管理專案結構

## 專案結構

```
CopilotChat/
├── CopilotChatApp.swift          # App 進入點
├── ContentView.swift             # 根視圖
├── Models/
│   ├── ChatModels.swift          # 資料模型（訊息、API 型別）
│   ├── AuthManager.swift         # GitHub Device Flow OAuth
│   ├── CopilotService.swift      # Chat Completions API + SSE
│   ├── MCPClient.swift           # MCP JSON-RPC client
│   └── SettingsStore.swift       # 設定持久化
├── Views/
│   ├── ChatView.swift            # 聊天介面
│   ├── MessageView.swift         # 訊息氣泡
│   ├── MarkdownView.swift        # Markdown 渲染器
│   ├── SettingsView.swift        # 設定頁
│   ├── MCPSettingsView.swift     # MCP server 管理
│   └── ModelPickerView.swift     # 模型選擇
└── Utilities/
    └── KeychainHelper.swift      # Keychain 封裝
```

## 重新產生 Xcode 專案

如果修改了 `project.yml`：

```bash
brew install xcodegen  # 安裝 XcodeGen（如果沒有）
xcodegen generate
```
