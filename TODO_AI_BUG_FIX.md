# TODO - AI 修 bug 記錄

## 2026-04-13

---

## 🔴 高優先：MCP Server 不穩定問題

### 問題描述
`github_push` 工具呼叫時，伺服器偶發性回傳 `Invalid response from MCP server` 錯誤。

### 觀察到的行為
| 嘗試 | 參數 | 結果 |
|------|------|------|
| 第1次 | 無 | ❌ Invalid response |
| 第2次 | 無 | ❌ Invalid response |
| 第3次 | `message:"push with force flag"` | ✅ 成功 |

### 🚨 發現的 Workaround
**在 `github_push` 加上 `message` 參數就能成功！**
```swift
github_push(message: "任意 commit message") // ✅ 成功
github_push()                               // ❌ 失敗
```
這可能是 MCP server 在處理某些請求時進入了無效狀態，加上額外參數後會走不同的 code path。

### 根本原因（推測）
- `Invalid response from MCP server` 意味著 server 回了一個 client 無法解析的 response
- 可能原因：
  1. Server 回應了非 JSON 格式的資料
  2. Server 在某些請求下 crash 或進入了無效狀態
  3. Server 內部狀態機制有 bug
  4. Server 在處理某些 git 操作時進入僵屍狀態

### 發生位置
- `MCPClient.swift:82` 和 `MCPClient.swift:132` - 拋出 `MCPError.invalidResponse`
- MCP server 實作不在這個 codebase 裡

### 待修復
- [ ] 確認 MCP server 實作位置
- [ ] 加入 timeout 設定（目前在 `performHTTPRequest` 沒有 timeout）
- [ ] 檢查 server 端的狀態機制
- [ ] 加入重試機制或更好的錯誤處理

---

## 🟡 中優先：Git Pull 功能問題（已修復）

### 問題描述
`git pull` 拉不到最新的 commit，本地落後至少 5 個 commit。

### 根本原因
- `Repository.swift` 的 `fetch()` 方法沒有指定 refspec
- `git_remote_fetch(pointer, nil, &opts, nil)` - 傳入 `nil` 表示使用預設 refspec
- 預設行為只下載物件到 `.git/objects/`，**不會更新** `refs/remotes/origin/main`
- 因此 `checkout(strategy: .Force)` 永遠 checkout 舊的 commit

### 修復內容

**1. `CopilotChat/Models/SwiftGit/Repository.swift`**
- `fetch()` 方法新增 `refspecs: [String]?` 參數
- 當有指定 refspecs 時，明確傳遞給 `git_remote_fetch`
- 向後相容：不傳時仍使用預設行為

```swift
public func fetch(_ remote: Remote, refspecs: [String]? = nil, credentials: Credentials = .default) -> Result<(), NSError> {
    // ... 當有 refspecs 時，使用 git_strarray 傳遞
}
```

**2. `CopilotChat/Models/GitHubPlugin.swift`**
- pull 方法 fetch 時明確指定 `+refs/heads/main:refs/remotes/origin/main`

```swift
let refspec = "+refs/heads/main:refs/remotes/origin/main"
let fetchResult = repo.fetch(remote, refspecs: [refspec], credentials: creds)
```

### Commit
- Hash: `902c7ad`
- Message: "fix: update fetch to explicitly update remote tracking refs on pull"

---

## 🟢 已排除：GitHub 本身狀態

- GitHub Status API (`api.github.com`) 回應正常
- GitHub.com 本身沒有掛（2026-04-13 09:30 UTC）

---

## 📝 待檢查：MCPClient 其他問題

### 缺少 Timeout 設定
位置：`MCPClient.swift:165`
```swift
return try await URLSession.shared.data(for: request)
```
URLSession 預設 timeout 是無限的，網路不稳時可能造成工具無限期卡住。

### 建議修改
```swift
var request = URLRequest(url: url)
request.timeoutInterval = 30 // 或其他合理值
```

---

## 📋 整理清單

### 需檢查的檔案
1. `CopilotChat/Models/MCPClient.swift` - timeout 設定、重試機制
2. MCP Server 實作（不在此 repo） - 穩定性問題

### 待 push 的 commit（如果有）
- `902c7ad` - fetch fix（可能需要 rebase 或 amend）

---

## 🔗 相關連結

- Repo: https://github.com/jason5545/CopilotChat
- 問題 commit: `902c7ad`
- 測試 branch: `main`

---

## 💡 備註

用另一個 AI 修的時候，可以把這個檔案餵給它，讓它了解所有問題的來龍去脈。