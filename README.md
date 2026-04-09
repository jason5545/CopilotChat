# CopilotChat for iOS

把 GitHub Copilot 的聊天功能帶到 iOS。純 SwiftUI，不依賴第三方框架。

第一個在 iOS 上原生支援 MCP（Model Context Protocol）tool call 自動執行的 Copilot 客戶端。

## 功能

### 核心

- GitHub Copilot Chat（OpenAI-compatible API）
- Streaming response，即時顯示回應
- Markdown 渲染（標題、粗體、斜體、程式碼區塊、列表、引用）
- 模型選擇（claude-opus-4-6、gpt-4o 等）

### MCP 工具自動執行

- MCP（Model Context Protocol）Streamable HTTP transport
- 多 MCP server 管理
- Tool call 自動執行（最多 10 輪 completion loop）
- 三層權限控制（tool > server > session）

### 多 Provider

參考 [models.dev](https://models.dev)，支援 120+ providers：

- **GitHub Copilot** — Chat Completions + Responses API 雙路徑
- **OpenAI Compatible** — Z.AI、Zhipu、Alibaba、Tencent、xAI、Groq、OpenRouter 等 80+
- **Anthropic Compatible** — Anthropic 直連
- **Gemini** — Google AI Studio
- **OpenAI Codex** — Codex CLI endpoint

### 內建工具

- `web_fetch` — 抓取網頁內容
- `web_screenshot` — 網頁截圖
- `brave_web_search` — Brave 搜尋（API key 存 Keychain）

### 對話管理

- JSON 檔案持久化對話歷史（`Documents/Conversations/`）
- Auto-compaction（95% context window 觸發摘要壓縮）
- Context window 圓形指示器（nav bar 顯示 token 用量）

### 設計

- Carbon 設計系統（深炭黑 + 琥珀色 #F59E0B）
- 三重字型（New York 襯線 / SF Mono 等寬 / SF Pro 無襯線）
- Thinking / reasoning block 顯示（各 provider 欄位名稱自適應）

## 需求

- iOS 26+
- Xcode 26+
- GitHub 帳號（有 Copilot 訂閱）或任何支援的 provider API key

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

### 登入

**GitHub Copilot：**

1. 開啟 App → 點右上角齒輪 → **Settings**
2. 點 **Sign in with GitHub**
3. App 會顯示一組驗證碼和 GitHub 連結
4. 在瀏覽器開啟連結，輸入驗證碼
5. 授權後 App 會自動完成登入

**其他 Provider：**

在 Settings 中選擇 provider，填入 API key 即可。支援 models.dev 上的所有 provider。

### 聊天

登入後直接在輸入框打字，按送出即可。預設模型為 `claude-sonnet-4-6`，可在設定中更改。

### 設定 MCP Server

1. 到 **Settings → MCP Servers → Add MCP Server**
2. 填入：
   - **Name**: 顯示名稱（例如 `memory-connect`）
   - **URL**: Server endpoint（例如 `https://your-worker.workers.dev/mcp`）
   - **Headers**: 認證 header，每行一個（例如 `Authorization: Bearer your-token`）
3. 儲存後 App 會自動連線並載入 tools

MCP tools 會自動注入到 API 的 `tools` 參數中。當 AI 回應包含 tool call 時，App 會自動透過 MCP server 執行並回傳結果，整個過程不需要手動介入。

## 認證流程

GitHub Copilot 使用 Device Flow OAuth：

1. 向 GitHub 請求 device code
2. 使用者在瀏覽器授權
3. App 取得 OAuth token
4. 用 OAuth token 作為 Bearer token 呼叫 `api.githubcopilot.com`

使用獨立的 OAuth Client ID 進行認證。

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
├── CopilotChatApp.swift              # App 進入點
├── ContentView.swift                 # 根視圖
├── DesignSystem.swift                # Carbon 設計系統
├── Models/
│   ├── AuthManager.swift             # GitHub Device Flow OAuth
│   ├── BuiltInTools.swift            # 內建工具（web_fetch、brave_search）
│   ├── ChatModels.swift              # 資料模型（訊息、API 型別）
│   ├── Conversation.swift            # 對話模型
│   ├── ConversationStore.swift       # 對話歷史持久化
│   ├── CopilotService.swift          # Chat Completions API + SSE
│   ├── MCPClient.swift               # MCP JSON-RPC client
│   ├── MarkdownParser.swift          # Markdown 解析
│   ├── SettingsStore.swift           # 設定持久化
│   └── WebFetchService.swift         # 網頁抓取服務
├── Providers/
│   ├── LLMProvider.swift             # Provider 協定
│   ├── CopilotProvider.swift         # GitHub Copilot
│   ├── OpenAICompatibleProvider.swift # Z.AI、OpenRouter 等
│   ├── AnthropicCompatibleProvider.swift # Anthropic 直連
│   ├── GeminiProvider.swift          # Google Gemini
│   ├── OpenAICodexProvider.swift     # OpenAI Codex
│   ├── ProviderRegistry.swift        # Provider 註冊
│   ├── ProviderTransform.swift       # Provider 轉換
│   ├── ModelsDev.swift               # models.dev 資料
│   └── SSEParser.swift               # SSE 串流解析
├── Views/
│   ├── ChatView.swift                # 聊天介面
│   ├── ConversationHistoryView.swift # 對話歷史
│   ├── MessageView.swift             # 訊息渲染
│   ├── MarkdownView.swift            # Markdown 渲染器
│   ├── MCPSettingsView.swift         # MCP server 管理
│   ├── ModelPickerView.swift         # 模型選擇
│   └── SettingsView.swift            # 設定頁
├── Agents/
│   └── AgentConfig.swift             # Agent 設定
└── Utilities/
    └── KeychainHelper.swift          # Keychain 封裝
```

## 相關文件

- [`docs/zai-glm51-tool-calling-investigation.md`](docs/zai-glm51-tool-calling-investigation.md) — Z.AI GLM-5.1 tool calling identity drift 調查報告

## 重新產生 Xcode 專案

如果修改了 `project.yml`：

```bash
brew install xcodegen  # 安裝 XcodeGen（如果沒有）
xcodegen generate
```

## License

MIT
