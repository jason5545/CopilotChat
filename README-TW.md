# CopilotChat for Apple 平台

<p align="center">
  <img src="docs/images/app-icon.webp" alt="CopilotChat" width="128">
</p>

[English](./README.md)

支援 iPhone、iPad 與 macOS 的 Apple 平台原生多 Provider LLM 聊天客戶端。純 SwiftUI，零第三方依賴。

把 GitHub Copilot、多 Provider、MCP tool call 自動執行、workspace-aware coding mode，以及 macOS 終端工作流整合在同一個原生 app 裡。

## 功能

### 多 Provider

參考 [models.dev](https://models.dev)，支援 120+ providers：

- **GitHub Copilot** — Device Flow OAuth 登入，Chat Completions + Responses API 雙路徑
- **Augment Code** — Session JSON 認證，NDJSON streaming，tenant-based 架構
- **OpenAI Compatible** — Z.AI、Zhipu、Alibaba、Tencent、xAI、Groq、OpenRouter 等 80+
- **Anthropic Compatible** — Anthropic 直連
- **Gemini** — Google AI Studio（API key 透過 HTTP header 傳送）
- **OpenAI Codex** — Codex CLI endpoint（PKCE OAuth）

每個 provider 有各自的認證方式、串流協定（SSE / NDJSON）、thinking/reasoning token 處理邏輯。切換 provider 時自動記住各 provider 上次選擇的模型。

### MCP 工具自動執行

- MCP（Model Context Protocol）Streamable HTTP transport
- 多 MCP server 管理（headers 安全儲存於 Keychain）
- Tool call 自動執行（最多 10 輪 completion loop）
- 三層權限控制（tool > server > session）
- `tool_search` — deferred loading 模式，讓模型按需載入 MCP 工具

### 內建工具

- `web_fetch` — 抓取網頁內容（WKWebView，非持久化 session）
- `web_screenshot` — 網頁截圖（支援 vision 模型）
- `brave_web_search` — Brave 搜尋（API key 存 Keychain）
- `tool_search` — MCP 工具搜尋（deferred loading 模式下自動注入）
- `switch_mode` — chat / coding 協調者模式切換
- **檔案操作**（workspace，iOS sandbox 內）：
  - `list_files` — 目錄列表，支援遞迴模式，自動跳過 `.git`/`build`/`node_modules`
  - `read_file` — 讀取檔案內容，附行號、offset/limit 分頁、10MB 大小上限
  - `write_file` — 寫入/覆寫檔案，自動建立上層目錄
  - `edit_file` — 精準搜尋替換（單次或全部匹配），回應顯示行數變化
  - `create_file` — 建立檔案，可附初始內容，自動建立上層目錄
  - `delete_file` — 刪除檔案或空目錄
  - `copy_file` — 複製檔案或目錄，自動建立上層目錄
  - `move_file` — 搬移/重新命名檔案或目錄，支援搬入目錄語義
  - `grep_files` — 正則表達式內容搜尋，支援上下文行、檔案過濾、二進位偵測、匹配摘要
- `bash` — 僅限 macOS 的終端工具，可在選定 workspace 中執行 zsh 指令並串流顯示輸出

### Coding Mode

- 橫跨 iPhone、iPad 與 macOS 的 chat / coding 雙模式 UI
- coding mode 採 coordinator flow：模型先呼叫 `switch_mode`，再使用檔案工具
- Quick Search 可搜尋動作、對話與已儲存專案（macOS 支援 `Cmd + K`）
- coding 對話會綁定 workspace，並在 iPad/macOS 側邊欄以專案樹分組顯示
- 透過系統資料夾選擇器選擇專案；security-scoped bookmark 讓同裝置上已授權的資料夾可重開與快速切換
- 恢復 coding 對話時，只要 bookmark 還在，就會自動切回對應 workspace
- mode-aware filtering：chat mode 不暴露 coding-only tools，也不顯示 project/workspace quick-search 項目

### Community Plugins（.cex）

- JavaScriptCore sandbox 外掛系統
- 使用者透過 Files app 匯入 `.cex` plugin bundle（`manifest.json` + `index.js`）
- 受控 API 存取：network（domain whitelist）、clipboard、notification、openURL
- Chat 和 Coding mode 都可使用
- 範例外掛：`plugins/github-cex/`（GitHub REST API 工具）

### 對話管理

- JSON 檔案持久化對話歷史（`Documents/Conversations/`）
- Auto-compaction（95% context window 觸發摘要壓縮）
- Context window 圓形指示器（nav bar 顯示 token 用量）
- 對話自動命名
- 編輯訊息 / 重新生成
- coding 歷史會保留 workspace 關聯，方便可靠地重開各專案對話

### 設計

- Carbon 設計系統（深炭黑 + 琥珀色 #F59E0B）
- 三重字型（New York 襯線 / SF Mono 等寬 / SF Pro 無襯線）
- Thinking / reasoning block 顯示（各 provider 欄位名稱自適應）

### 安全性

- 所有 token 和 API key 儲存於 Keychain（`kSecAttrAccessibleAfterFirstUnlock`）
- MCP server headers 儲存於 Keychain（不經 UserDefaults）
- 全程 HTTPS，無 ATS 例外
- Gemini API key 透過 HTTP header 傳送（不暴露在 URL 中）
- 零第三方依賴，無供應鏈風險

## 需求

- iOS 26+
- macOS 26+
- Xcode 26+
- GitHub 帳號（有 Copilot 訂閱）或任何支援的 provider API key

## 安裝步驟

### 1. 開啟專案

```bash
open CopilotChat.xcodeproj
```

### 2. 設定簽名

1. 在 Xcode 中選擇 iPhone/iPad 用的 **CopilotChat** target，或 macOS 用的 **CopilotChatMac** target
2. 到 **Signing & Capabilities**
3. 選擇你的 **Development Team**（Personal Team 即可）
4. 如果 Bundle Identifier 衝突，改成唯一的（例如 `com.yourname.copilotchat`）

### 3. 執行 App

1. 若要跑 iPhone/iPad，使用 USB 連接裝置並選擇 **CopilotChat** scheme
2. 若要跑 macOS，選擇 **My Mac** 和 **CopilotChatMac** scheme
3. 按 **Cmd + R** 編譯並執行
4. iPhone/iPad 首次安裝後，需要到裝置上：**設定 → 一般 → VPN 與裝置管理** → 信任開發者

## 使用方式

### 登入

**GitHub Copilot：**

1. 開啟 App → 點右上角齒輪 → **Settings**
2. 點 **Sign in with GitHub**
3. App 會顯示一組驗證碼和 GitHub 連結
4. 在瀏覽器開啟連結，輸入驗證碼
5. 授權後 App 會自動完成登入

**Augment Code：**

在 Settings 中選擇 Augment provider，貼上 Session JSON（包含 tenant URL 和 API key）。

**其他 Provider：**

在 Settings 中選擇 provider，填入 API key 即可。支援 models.dev 上的所有 provider。

### 聊天

登入後直接在輸入框打字，按送出即可。預設模型為 `claude-sonnet-4-6`，可在設定中更改。

### Quick Search

1. 點放大鏡按鈕開啟 Quick Search；在 macOS 也可按 **Cmd + K**
2. chat mode 只會顯示動作與聊天對話
3. coding mode 會額外顯示專案、coding 對話，以及 `/project` workspace 切換搜尋

### Coding Mode / Workspace

1. 點 nav bar 右上角的 mode 圖示切到 coding mode
2. 在 empty state 點 **Choose Folder** 選擇專案資料夾
3. 可用 Quick Search 重開專案對話或用 `/project` 切換 workspace；在 iPhone 上資料夾按鈕會直接進入專案搜尋
4. 在 iPad 與 macOS 上，側邊欄會依專案分組 coding 對話；在 iPhone 上，workspace 視窗會顯示 **Saved Projects**
5. 模型可透過 `tool_search` 找到目前 mode 可用的工具
6. 檔案修改優先使用 `edit_file`（精準 replace / patch-style 編輯）
7. 在 macOS 上，coding mode 也會暴露 `bash` 工具，方便在選定 workspace 中跑本機 CLI 工作流

![Coding mode workspace picker](docs/images/coding-mode-workspace.webp)

### 設定 MCP Server

1. 到 **Settings → MCP Servers → Add MCP Server**
2. 填入：
   - **Name**: 顯示名稱（例如 `memory-connect`）
   - **URL**: Server endpoint（例如 `https://your-worker.workers.dev/mcp`）
   - **Headers**: 認證 header，每行一個（例如 `Authorization: Bearer your-token`）
3. 儲存後 App 會自動連線並載入 tools

MCP tools 會自動注入到 API 的 `tools` 參數中。當 AI 回應包含 tool call 時，App 會自動透過 MCP server 執行並回傳結果，整個過程不需要手動介入。

內建 file tools 不走 MCP server，而是直接在 app 內透過 workspace 權限執行。

### Community Plugins

1. 下載 `.cex` plugin bundle（包含 `manifest.json` 和 `index.js` 的資料夾）
2. 到 **Settings → Plugins → Community Plugins → Import from Files...**
3. 選擇 plugin 資料夾
4. 載入後，這些工具可在 chat 與 coding mode 中使用

## 認證流程

| Provider | 認證方式 |
|----------|----------|
| GitHub Copilot | Device Flow OAuth（獨立 OAuth Client ID） |
| Augment Code | Session JSON（tenant URL + API key） |
| OpenAI Codex | PKCE OAuth（Authorization Code Flow） |
| 其他 | API key（Keychain 儲存） |

## 技術架構

- **Swift 6** strict concurrency
- **@Observable** macro（Observation framework）
- **URLSession async/await** + `bytes(for:)` SSE / NDJSON streaming
- **Keychain** 安全儲存所有 credentials
- **MCP Streamable HTTP** transport（JSON-RPC over HTTP）
- **JavaScriptCore** sandbox 執行社群外掛
- **XcodeGen** 管理專案結構（`project.yml` 為唯一真實來源）
- **零第三方依賴**

## 專案結構

以下列出主要檔案：

```
CopilotChat/
├── CopilotChatApp.swift              # App 進入點
├── ContentView.swift                 # 根視圖
├── DesignSystem.swift                # Carbon 設計系統
├── Models/
│   ├── AuthManager.swift             # GitHub Device Flow OAuth
│   ├── CExtPlugin.swift              # .cex plugin wrapper
│   ├── CExtPluginManager.swift       # 社群外掛管理
│   ├── ChatModels.swift              # 資料模型（訊息、API 型別）
│   ├── Conversation.swift            # 對話模型
│   ├── ConversationStore.swift       # 對話歷史持久化
│   ├── CopilotService.swift          # Chat Completions API + SSE
│   ├── FileMentionManager.swift      # @file 索引與過濾
│   ├── FileSystemPlugin.swift        # coding mode 檔案工具 + workspace 存取
│   ├── GitHubPlugin.swift            # 內建 GitHub 工具
│   ├── JavaScriptCorePluginLoader.swift # JSContext sandbox 載入器
│   ├── MCPClient.swift               # MCP JSON-RPC client
│   ├── MarkdownParser.swift          # Markdown 解析
│   ├── PluginSystem.swift            # 內建 plugin / tool registry
│   ├── QuickSearchStore.swift        # 全域 quick-search 狀態
│   ├── SettingsStore.swift           # 設定持久化
│   ├── TerminalPlugin.swift          # macOS bash 工具
│   ├── TerminalSessionTracker.swift  # 終端視窗/工作階段狀態
│   └── WebFetchService.swift         # 網頁抓取服務
├── Providers/
│   ├── LLMProvider.swift             # Provider 協定
│   ├── CopilotProvider.swift         # GitHub Copilot
│   ├── AugmentProvider.swift         # Augment Code（NDJSON streaming）
│   ├── OpenAICompatibleProvider.swift # Z.AI、OpenRouter 等
│   ├── AnthropicCompatibleProvider.swift # Anthropic 直連
│   ├── GeminiProvider.swift          # Google Gemini
│   ├── OpenAICodexProvider.swift     # OpenAI Codex（PKCE OAuth）
│   ├── ProviderRegistry.swift        # Provider 註冊與路由
│   ├── ProviderTransform.swift       # Provider 轉換
│   ├── ModelsDev.swift               # models.dev 資料
│   └── SSEParser.swift               # SSE 串流解析
├── Views/
│   ├── CExtPluginsView.swift         # 社群外掛管理 UI
│   ├── ChatView.swift                # 聊天介面
│   ├── ConversationHistoryView.swift # 對話歷史
│   ├── FileMentionPicker.swift       # @file 建議 UI
│   ├── MessageView.swift             # 訊息渲染
│   ├── MarkdownView.swift            # Markdown 渲染器
│   ├── MCPSettingsView.swift         # MCP server 管理
│   ├── ModelPickerView.swift         # 模型選擇
│   ├── QuickSearchView.swift         # 命令面板式搜尋 UI
│   ├── SettingsView.swift            # 設定頁
│   ├── SidebarView.swift             # Workspace/專案樹側邊欄
│   ├── TerminalMessageView.swift     # 終端工具訊息渲染
│   ├── TerminalWindowView.swift      # macOS 終端輸出視窗
│   └── WorkspaceSelectorView.swift   # 專案資料夾選擇 UI
├── Agents/
│   └── AgentConfig.swift             # Agent 設定
├── Utilities/
│   ├── ConversationNavigator.swift   # 共用對話/workspace 切換邏輯
│   ├── KeychainHelper.swift          # Keychain 封裝
│   ├── PlatformHelpers.swift         # 跨平台相容輔助
│   └── SecureStorage.swift           # 安全 token 儲存輔助
└── plugins/
    └── github-cex/                   # 範例 .cex plugin（GitHub API）
```

## 相關文件

- [`docs/zai-glm51-tool-calling-investigation.md`](docs/zai-glm51-tool-calling-investigation.md) — Z.AI GLM-5.1 tool calling identity drift 調查報告

## 重新產生 Xcode 專案

如果修改了 `project.yml`，或新增/移除了 source files：

```bash
brew install xcodegen  # 安裝 XcodeGen（如果沒有）
xcodegen generate
```

`project.yml` 是專案結構的唯一真實來源。避免手動編輯 `CopilotChat.xcodeproj`。

## 致謝

社群外掛系統（.cex）的設計靈感來自 [OpenCode](https://github.com/anomalyco/opencode) 的外掛架構。

## License

MIT
