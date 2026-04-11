let _token = null;

function set_token(args) {
    _token = args.token;
    return "GitHub token set.";
}

function _headers() {
    const h = { "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" };
    if (_token) h["Authorization"] = "Bearer " + _token;
    return h;
}

function _request(method, path, body) {
    const url = "https://api.github.com" + path;
    const opts = { method: method, headers: _headers() };
    if (body) opts.body = JSON.stringify(body);
    const raw = bridge.fetch(url, JSON.stringify(opts));
    const result = JSON.parse(raw);
    if (!result.ok) throw new Error("GitHub " + result.status + ": " + (result.text || "").substring(0, 200));
    return result.json || result.text || result.data || {};
}

const tools = [
    { name: "set_token", description: "Set GitHub Personal Access Token. Get one at https://github.com/settings/tokens",
      args: [{ name: "token", type: "string", description: "GitHub PAT", required: true }] },
    { name: "github_list_issues", description: "List issues in a repository",
      args: [{ name: "owner", type: "string", description: "Repo owner", required: true },
             { name: "repo", type: "string", description: "Repo name", required: true },
             { name: "state", type: "string", description: "open/closed/all (default: open)", required: false },
             { name: "per_page", type: "integer", description: "Results per page (default: 10)", required: false }] },
    { name: "github_create_issue", description: "Create a new issue",
      args: [{ name: "owner", type: "string", description: "Repo owner", required: true },
             { name: "repo", type: "string", description: "Repo name", required: true },
             { name: "title", type: "string", description: "Issue title", required: true },
             { name: "body", type: "string", description: "Issue body", required: false }] },
    { name: "github_get_file", description: "Get a file from a repository",
      args: [{ name: "owner", type: "string", description: "Repo owner", required: true },
             { name: "repo", type: "string", description: "Repo name", required: true },
             { name: "path", type: "string", description: "File path", required: true },
             { name: "ref", type: "string", description: "Branch or SHA", required: false }] },
    { name: "github_search_repos", description: "Search for repositories",
      args: [{ name: "q", type: "string", description: "Search query", required: true },
             { name: "per_page", type: "integer", description: "Results (default: 5)", required: false }] },
    { name: "github_add_comment", description: "Comment on an issue or PR",
      args: [{ name: "owner", type: "string", description: "Repo owner", required: true },
             { name: "repo", type: "string", description: "Repo name", required: true },
             { name: "issue_number", type: "integer", description: "Issue/PR number", required: true },
             { name: "body", type: "string", description: "Comment text", required: true }] }
];

function github_list_issues(args) {
    const state = args.state || "open";
    const per_page = Math.min(args.per_page || 10, 100);
    const data = _request("GET", "/repos/" + args.owner + "/" + args.repo + "/issues?state=" + state + "&per_page=" + per_page);
    if (!Array.isArray(data)) return JSON.stringify(data);
    return data.map(function(i) {
        return "#" + i.number + " [" + i.state + "] " + i.title + "\n  " + i.user.login + " | " + i.comments + " comments\n  " + i.html_url;
    }).join("\n\n");
}

function github_create_issue(args) {
    const data = _request("POST", "/repos/" + args.owner + "/" + args.repo + "/issues", { title: args.title, body: args.body || "" });
    return "Created #" + data.number + "\n" + data.html_url;
}

function github_get_file(args) {
    const ref = args.ref || "main";
    const data = _request("GET", "/repos/" + args.owner + "/" + args.repo + "/contents/" + args.path + "?ref=" + encodeURIComponent(ref));
    if (data.content) {
        return "File: " + data.path + " (" + data.size + " bytes)\n```\n" + atob(data.content.replace(/\n/g, "")) + "\n```";
    }
    return JSON.stringify(data);
}

function github_search_repos(args) {
    const per_page = Math.min(args.per_page || 5, 30);
    const data = _request("GET", "/search/repositories?q=" + encodeURIComponent(args.q) + "&per_page=" + per_page + "&sort=stars");
    if (!data.items) return JSON.stringify(data);
    return data.items.map(function(r) {
        return r.full_name + " | " + r.stargazers_count + " stars | " + (r.language || "N/A") + "\n  " + (r.description || "") + "\n  " + r.html_url;
    }).join("\n\n");
}

function github_add_comment(args) {
    const data = _request("POST", "/repos/" + args.owner + "/" + args.repo + "/issues/" + args.issue_number + "/comments", { body: args.body });
    return "Comment added: " + data.html_url;
}

module.exports = {
    tools: tools,
    set_token: set_token,
    github_list_issues: github_list_issues,
    github_create_issue: github_create_issue,
    github_get_file: github_get_file,
    github_search_repos: github_search_repos,
    github_add_comment: github_add_comment
};
