# Investigation: Copilot API Token Limits Discrepancy

## Problem
CopilotChat gets lower `max_context_window_tokens` from `api.githubcopilot.com/models` compared to VS Code for the same Pro+ account.

| Model | CopilotChat | VS Code |
|-------|------------|---------|
| claude-opus-4.6 | 160,000 | 192,000 |
| claude-sonnet-4 | 216,000 | ? |

## What We Tried
1. **Full VS Code-compatible request headers** — Matched `User-Agent`, `Copilot-Integration-Id`, `Editor-Version`, `Editor-Plugin-Version`, `x-github-api-version`, `x-request-id`, and `x-vscode-user-agent-library-version`. The iPhone app still returned 144K for `claude-opus-4.6`.
2. **Token exchange with current app token** — `GET api.github.com/copilot_internal/v2/token` returns 404 with our current OAuth token.
3. **On-device validation after redeploy** — Header parity changes were built, deployed, and tested on the iPhone. The limit remained 144K.
4. **VS Code OAuth app identity test** — Switched the app to the VS Code-compatible client ID `Iv1.b507a08c87ecfe98`, forced re-auth, and tested on-device. This also caused GitHub to show the `GitHub Copilot Plugin by GitHub` OAuth permission prompt.
5. **Rollback to app identity + OpenCode headers** — Restored the app OAuth client ID `Ov23li8tweQw6odWQebz` and reverted request headers to OpenCode-style values while keeping the display-only token interpretation change.
6. **Display-only context interpretation change** — After changing the app UI to prefer `max_prompt_tokens + max_output_tokens`, `claude-opus-4.6` now shows `160K` on-device instead of `144K`.

## Current Conclusions
1. **The iPhone app currently uses a raw GitHub OAuth token directly against Copilot API.**
   - `AuthManager.swift` stores a GitHub OAuth token from device flow.
   - `CopilotService.swift` sends that token directly as `Authorization: Bearer ...` to `https://api.githubcopilot.com/models` and chat endpoints.
   - No Copilot token exchange exists in the app.

2. **VS Code's Copilot SDK also supports a direct OAuth-token path.**
   - The installed SDK constructs the Copilot client via `createWithOAuthToken(...).listModels()`.
   - That means token exchange is **not required** just to call `/models`.
   - So the limit mismatch cannot be explained solely by “our app does not exchange for a Copilot JWT”.

3. **Request-shape mismatch is no longer the leading theory.**
   - We matched the known VS Code-compatible headers on-device.
   - The returned limit still stayed at 144K.
   - That effectively rules out the obvious request-header differences as the cause.

4. **OAuth app identity is a meaningful differentiator, but is no longer the active app configuration.**
   - Our app is currently back on client ID `Ov23li8tweQw6odWQebz`.
   - We temporarily tested the VS Code-compatible client ID `Iv1.b507a08c87ecfe98`.
   - That test did not yet establish a confirmed token-limit improvement, and it changed GitHub's OAuth permission UI to `GitHub Copilot Plugin by GitHub`, which was undesirable for the app.
   - Both inspected flows use `read:user`, so scope mismatch remains a weaker explanation than client identity.

5. **The previous Mac keychain runtime check was invalid for this investigation.**
   - This is an iPhone app issue.
   - We should only trust source inspection or app-side/device-side logging, not macOS host keychain state.

6. **VS Code distinguishes raw `/models` payload from the model metadata it actually uses at runtime.**
   - The extension's debug logger renders a dedicated "Available Models (Raw API Response)" section for the `/models` payload.
   - Built-in Copilot-hosted models are then passed through the extension model service (`iS._hydrateResolvedModel(...)`), which can mutate `capabilities.limits.max_prompt_tokens` before endpoint creation.
   - The endpoint layer (`q9` / `ad`) then exposes runtime metadata such as `modelMaxPromptTokens`, so UI and request sizing do not have to match the raw debug dump.
   - That makes it plausible that VS Code can show `192K` while the raw `/models` payload still reports `144K`.

7. **The app's `160K` result proves display interpretation matters, but does not fully explain VS Code's `192K`.**
   - The app no longer shows the raw `144K` once it switches to display `max_prompt_tokens + max_output_tokens`.
   - The observed `160K` strongly suggests the app is now showing something like `144K prompt + 16K output`.
   - Since VS Code still shows `192K`, it is likely using a built-in override source or experiment-driven normalization path beyond the app's current payload.

8. **The strongest current VS Code-side explanation is a built-in prompt-token override path, not a header mismatch.**
   - The extension fetches raw `/models`, logs that raw data, then mutates built-in model metadata in `iS._hydrateResolvedModel(...)`.
   - That normalization path calls `_getMaxPromptTokensOverride(...)`, which reads a debug override and an experiment payload keyed by model id (`copilotchat.contextWindows`).
   - No hardcoded `claude-opus-4.6 -> 192K` constant was found in the inspected extension bundle, but this is the first proven built-in path that can change token limits after the raw payload is fetched.

## Investigation Directions

### 1. Raw display interpretation is still the safest active app fix path
We already matched the obvious VS Code-compatible headers and validated on the phone. The result did not change.

The app now mirrors the strongest observed VS Code display behavior by showing `max_prompt_tokens + max_output_tokens` in model-picking UI while preserving runtime use of `max_prompt_tokens`.

However, the latest on-device result is `160K`, not `192K`, so this should now be treated as a partial explanation rather than a full match with VS Code.

### 2. VS Code-side normalization is now the leading explanation for the remaining gap
The strongest new finding is that VS Code does not appear to rely solely on the raw `/models` payload for built-in Copilot-hosted models.

- raw `/models` is fetched and logged by the extension model service
- built-in models are then normalized in `iS._hydrateResolvedModel(...)`
- that path can override `max_prompt_tokens` via `_getMaxPromptTokensOverride(...)`
- endpoint objects later expose `modelMaxPromptTokens`, which is what the rest of the extension uses

This means the remaining `160K` vs `192K` gap is now more likely to be caused by VS Code-only override metadata than by request headers.

### 3. Treat OAuth client identity as a secondary diagnostic branch if parity fails
Different OAuth apps may receive different Copilot API behavior even with the same human account.

- **Our app**: `Ov23li8tweQw6odWQebz`, scope `read:user`
- **VS Code-compatible reference**: `Iv1.b507a08c87ecfe98`, scope `read:user`

Status of this branch:
- we tested the VS Code-compatible client ID `Iv1.b507a08c87ecfe98`
- we forced re-auth under that identity
- we then rolled back to the app client ID `Ov23li8tweQw6odWQebz` because the OAuth permission sheet branded the app as `GitHub Copilot Plugin by GitHub`

If this branch is revisited later, it should be treated as a deliberate diagnostic tradeoff rather than the default app configuration.

### 4. Token exchange is still useful as a diagnostic, but no longer the primary theory
`copilot_internal/v2/token` remains relevant because:
- the endpoint works in reverse-engineered clients built around VS Code-compatible auth
- our current token gets 404

But since the VS Code SDK can call `/models` directly with an OAuth token, token exchange should now be treated as a **secondary signal about auth identity**, not the main missing feature.

### 5. Validate on-device with app-side logging if needed
If we need another proof step, add temporary app-side logging for `/models`:
- final request headers actually sent
- HTTP status code
- raw JSON limits returned for one or two affected models

If we need stronger parity evidence from VS Code itself, the equivalent proof points are:
- raw `/models` object before normalization
- normalized model object after `_hydrateResolvedModel(...)`
- endpoint fields such as `modelMaxPromptTokens` and `maxOutputTokens`

That keeps the investigation valid for the iPhone app instead of relying on host-machine assumptions.

### 6. Mirror VS Code's display interpretation without changing runtime limits
The app's runtime compaction logic should continue using `max_prompt_tokens`.

But for model-picker display, the app can safely show:
- `max_prompt_tokens + max_output_tokens` when both values are present
- otherwise fall back to raw `max_context_window_tokens`

This matches the strongest currently observed VS Code behavior while avoiding any change to request sizing or compaction behavior.

## Reference Implementation
- **ericc-ch/copilot-api**: Full reverse-engineered Copilot client with token exchange → `/tmp/copilot-api/`
- **opencode**: Hardcoded model limits, token exchange in `provider/copilot.go` → `/tmp/opencode/`
- **Headers reference**: `/tmp/copilot-api/src/lib/api-config.ts`

## Key Source Findings
- **App auth**: `CopilotChat/CopilotChat/Models/AuthManager.swift`
  - current client ID: `Ov23li8tweQw6odWQebz`
  - previously tested client ID: `Iv1.b507a08c87ecfe98`
  - scope: `read:user`
  - keychain slot is back to the app token key, and the VS Code token key is treated as legacy for forced cleanup
- **App model fetch**: `CopilotChat/CopilotChat/Models/CopilotService.swift`
  - direct `Bearer` call to `https://api.githubcopilot.com/models`
  - headers are currently back to OpenCode-style values:
    - `User-Agent: OpenCode/1.0`
    - `Editor-Version: OpenCode/1.0`
    - `Editor-Plugin-Version: OpenCode/1.0`
    - `Copilot-Integration-Id: vscode-chat`
- **VS Code-compatible reference auth**: `/tmp/copilot-api/src/lib/api-config.ts`
  - client ID: `Iv1.b507a08c87ecfe98`
  - scope: `read:user`
  - includes additional headers such as `x-request-id` and `x-vscode-user-agent-library-version`
- **VS Code SDK behavior**: installed `@github/copilot/sdk`
  - uses `createWithOAuthToken(...).listModels()`
  - confirms direct OAuth-token `/models` access is supported
- **VS Code extension behavior**: installed `github.copilot-chat` extension
  - debug logger labels the `/models` dump as raw API response
  - built-in Copilot models are fetched by the model service, logged raw, then normalized in `iS._hydrateResolvedModel(...)`
  - `_getMaxPromptTokensOverride(...)` can override `max_prompt_tokens` using debug settings or the `copilotchat.contextWindows` experiment payload keyed by model id
  - endpoint objects (`q9` / `ad`) then expose runtime values such as `modelMaxPromptTokens`
  - `p9(...)` separately synthesizes display metadata with `max_context_window_tokens = maxInputTokens + maxOutputTokens` for another model-metadata path
  - package schema for custom/provider models includes default snippets such as `maxInputTokens: 128000` and `maxOutputTokens: 16000`, reinforcing that the extension has multiple non-raw model metadata paths

## Current CopilotChat Files
- `CopilotService.swift`: `buildURLRequest()` (headers), `fetchModels()` 
- `AuthManager.swift`: OAuth flow, no token exchange
- `ChatModels.swift`: `ModelsResponse.ModelInfo.Limits` struct decodes `max_context_window_tokens`, `max_prompt_tokens`, `max_output_tokens`; display metadata now derives a VS Code-style display context size separately from runtime prompt limits

## Current App State
- OAuth client identity is back to the app's own client ID: `Ov23li8tweQw6odWQebz`
- Copilot request headers are back to OpenCode-style values
- Model picker/settings UI now displays a VS Code-style context size derived from `max_prompt_tokens + max_output_tokens` when both values are available
- Current observed on-device display for `claude-opus-4.6` is `160K`
- Runtime compaction logic still uses `max_prompt_tokens`
