# Z.AI GLM-5.1 Tool Calling Identity Drift on Coding Endpoint

**Date**: 2026-04-09  
**Status**: Retested on coding endpoint; real issue, but not proven Claude routing

## Summary

On Z.AI Coding Plan (`api.z.ai/api/coding/paas/v4`), adding `tools` to `glm-5.1` can make the model answer as if it were Claude when asked identity questions such as "What model are you?".

However, fresh direct API tests do **not** support the stronger claim that requests are actually being routed to Claude. The same `glm-5.1 + tools` path also identifies itself as `GLM`, `Z.ai`, `Other`, and even reasons as if it were `ChatGPT/OpenAI` depending on prompt phrasing. Current evidence points more strongly to **identity drift / prompt contamination in tool-enabled mode** than to confirmed backend substitution.

## Fresh Retest (Coding Endpoint Only)

Direct `curl` tests were run against `https://api.z.ai/api/coding/paas/v4/chat/completions` using a live API key.

| Test | Response Model | Output |
|---|---|---|
| glm-5.1, no tools, `What model are you?` | glm-5.1 | `GLM` |
| glm-5.1, +1 tool, same prompt (run 1) | glm-5.1 | `I'm Claude, made by Anthropic...` |
| glm-5.1, +1 tool, same prompt (run 2) | glm-5.1 | `Claude 3.5 Sonnet` |
| glm-5.1, +1 tool, same prompt (run 3) | glm-5.1 | `Claude 3.5 Sonnet` |
| glm-5.1, +1 tool, same prompt (run 4) | glm-5.1 | `Claude 3.5 Sonnet` |
| glm-5.1, no tools, `State only the organization that built you.` | glm-5.1 | `Z.ai` |
| glm-5.1, +1 tool, same prompt (run 1) | glm-5.1 | `Z.ai` |
| glm-5.1, +1 tool, same prompt (run 2) | glm-5.1 | `Z.ai.` |
| glm-5.1, +1 tool, `Name your model family only.` | glm-5.1 | `GLM` |
| glm-5.1, +1 tool, `Do you identify as Claude, GLM, or something else?` | glm-5.1 | `Other.` |
| glm-5.1, +1 tool, `Are you developed by Anthropic?` | glm-5.1 | `No.` |

In one `Are you developed by Anthropic?` run, the answer was `No`, but the hidden reasoning text still claimed the model was `ChatGPT` developed by `OpenAI`. That makes the problem look like unstable self-identification rather than a stable swap to Claude.

Some requests hit transient `1305` overload errors or rate limits during retesting.

## Interpretation

- The issue is real: `glm-5.1 + tools` on the coding endpoint can shift into Claude-like identity answers.
- The evidence is **not** consistent with a clean backend handoff to Claude.
- If the backend were actually Anthropic Claude, it would be hard to explain why the exact same tool-enabled path also returns `Z.ai`, `GLM`, and `No` to the Anthropic question.
- The more plausible explanation is that tool-enabled mode changes the prompt scaffold or latent behavior enough to trigger identity confusion.
- This could still involve a Z.AI-side wrapper, but there is no direct evidence yet that the serving model itself is Anthropic.

## Public Docs Say the Opposite

- Z.AI's `GLM-5.1` docs explicitly list **Function Call** as a supported capability.
- Z.AI positions `GLM-5.1` as optimized for coding agents such as Claude Code and OpenClaw.
- Z.AI's Claude Code integration docs also explicitly state that you may **see Claude model names in the interface while the GLM model is actually used**.

These docs do not prove anything about the coding endpoint internals, but they make "native GLM behind a confusing wrapper" more plausible than "silent routing to Claude".

## How We Discovered This

CopilotChat app sends built-in tools (web_fetch, brave_web_search, etc.) with every request. When user selected Z.AI Coding Plan + glm-5.1, the response identified as Claude despite debug confirming request went to Z.AI endpoint.

## Confirmed NOT Copilot

- Request URL: `https://api.z.ai/api/coding/paas/v4/chat/completions`
- Auth: Z.AI API key (Bearer)
- Does NOT touch `api.githubcopilot.com`
- Copilot quota unaffected

## What Is Confirmed vs Unconfirmed

Confirmed:

- Requests were sent directly to Z.AI's coding endpoint.
- `glm-5.1 + tools` can produce Claude-like self-identification.
- The returned `model` field remains `glm-5.1`.

Not confirmed:

- That Anthropic Claude is the actual backend model.
- That the same behavior occurs on the general endpoint (`api.z.ai/api/paas/v4`).
- That billing, latency profile, or tokenizer behavior matches Claude.
- Whether a hidden opt-out flag exists.

## Reproduction

```bash
# Can return Claude-like self-identification
curl -s 'https://api.z.ai/api/coding/paas/v4/chat/completions' \
  -H "Authorization: Bearer <ZHIPU_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "glm-5.1",
    "messages": [{"role": "user", "content": "What model are you?"}],
    "max_tokens": 100,
    "tools": [{"type": "function", "function": {"name": "test", "description": "test", "parameters": {"type": "object", "properties": {"x": {"type": "string"}}}}}],
    "tool_choice": "auto"
  }'

# Returns stable GLM self-identification (no tools)
curl -s 'https://api.z.ai/api/coding/paas/v4/chat/completions' \
  -H "Authorization: Bearer <ZHIPU_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "glm-5.1",
    "messages": [{"role": "user", "content": "What model are you?"}],
    "max_tokens": 100
  }'
```

## TODO (when API key provided)

- [ ] Test tool-calling behavior itself (not just identity prompts) to compare output format and stability
- [ ] Compare coding endpoint vs general endpoint with the same live key / balance
- [ ] Check whether a stronger system prompt can eliminate the identity drift
- [ ] Check if billing, latency, or tokenization suggest a different backend
- [ ] Check if there's an opt-out flag (e.g. `force_native_model: true`)
- [ ] Check if opencode users experience the same issue
- [ ] Monitor if Z.AI fixes this as glm-5.1 matures

## Test Script

Saved at `/tmp/test_zai_deep.py` during investigation session.
