# Z.AI GLM-5.1 Tool Calling Routes to Claude

**Date**: 2026-04-09  
**Status**: Pending deeper investigation (need fresh API key)

## Summary

Z.AI Coding Plan (`api.z.ai/api/coding/paas/v4`) silently routes glm-5.1 requests to Claude when `tools` parameter is present. Response `model` field still says `glm-5.1` but the actual output is from Claude.

## Test Results

| Test | Response Model | Actual Output |
|---|---|---|
| glm-5.1 bare | glm-5.1 | GLM (correct) |
| glm-5.1 + 1 tool | glm-5.1 | **Claude 3.5 Sonnet** |
| glm-5.1 + 3 tools | glm-5.1 | **Claude** |
| glm-5.1 + thinking only | glm-5.1 | GLM (correct) |
| glm-5.1 + thinking + 1 tool | glm-5.1 | GLM (correct) |
| glm-5.1 + thinking + 3 tools | glm-5.1 | **Claude** |
| glm-5 + 1 tool | glm-5.1 | GLM (correct) |
| glm-5-turbo + 1 tool | glm-5-turbo | Normal (correct) |
| glm-4.7 + 1 tool | glm-4.7 | Normal (correct) |
| glm-4.6 + 1 tool | glm-4.6 | Normal (correct) |

Only glm-5.1 is affected. Other GLM models handle tools natively.

## How We Discovered This

CopilotChat app sends built-in tools (web_fetch, brave_web_search, etc.) with every request. When user selected Z.AI Coding Plan + glm-5.1, the response identified as Claude despite debug confirming request went to Z.AI endpoint.

## Confirmed NOT Copilot

- Request URL: `https://api.z.ai/api/coding/paas/v4/chat/completions`
- Auth: Z.AI API key (Bearer)
- Does NOT touch `api.githubcopilot.com`
- Copilot quota unaffected

## Reproduction

```bash
# Returns Claude response
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

# Returns GLM response (no tools)
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

- [ ] Confirm which Claude version is being used (3.5 Sonnet? Haiku?)
- [ ] Check if billing differs when routed to Claude
- [ ] Check if there's an opt-out flag (e.g. `force_native_model: true`)
- [ ] Test with Z.AI's non-coding endpoint (`api.z.ai/api/paas/v4`) — same behavior?
- [ ] Check if opencode users experience the same issue
- [ ] Monitor if Z.AI fixes this as glm-5.1 matures

## Test Script

Saved at `/tmp/test_zai_deep.py` during investigation session.
