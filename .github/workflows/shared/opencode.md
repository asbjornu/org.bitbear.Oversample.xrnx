---
engine:
  id: opencode
  detection-engine: copilot
  version: "1.2.14"
  display-name: OpenCode
  description: OpenCode CLI with headless mode and multi-provider LLM support
  runtime-id: opencode
  experimental: true
  provider:
    name: openai
  behaviors:
    secret-strategy: universal-llm-consumer
    capabilities:
      max-turns: true
    manifest:
      files:
        - opencode.jsonc
        - AGENTS.md
      path-prefixes:
        - .opencode/
    network:
      defaults:
        - host.docker.internal
        - github.com
        - raw.githubusercontent.com
        - opencode.ai
        - models.dev
        # The built-in gh-aw threat-detection pass runs on the Copilot route
        # (`threat-detect --engine copilot`, GH_AW_LLM_PROVIDER: github) and
        # cannot be repointed from frontmatter, so its endpoint must stay
        # reachable even though the agent itself targets opencode.ai.
        - api.githubcopilot.com
      provider-domains:
        copilot: api.githubcopilot.com
        anthropic: api.anthropic.com
        # No `openai: api.openai.com` mapping: the agent's model prefix is
        # `openai` only because the AWF api-proxy exposes an OpenAI-compatible
        # route. The real upstream is OpenCode Zen (`opencode.ai`), reached by
        # the sidecar, so mapping the `openai` prefix to api.openai.com would
        # grant the agent an unintended direct egress path it never needs.
        google: generativelanguage.googleapis.com
        groq: api.groq.com
        mistral: api.mistral.ai
        deepseek: api.deepseek.com
        xai: api.x.ai
    installation:
      package-manager: npm
      package-name: opencode-ai
      step-name: Install OpenCode CLI
      binary-name: opencode
      include-node-setup: true
      cooldown: true
      verify-command: opencode --version
      verify-step-name: Verify OpenCode CLI installation
      docs-url: https://opencode.ai/docs
    config-file:
      path: opencode.jsonc
      step-name: Write OpenCode Config
      content: |-
        {
          "agent": {
            "build": {
              "permission": {
                "bash": "allow",
                "edit": "allow",
                "read": "allow",
                "glob": "allow",
                "grep": "allow",
                "webfetch": "allow",
                "websearch": "allow",
                "external_directory": "allow"
              }
            }
          },
          "autoupdate": false,
          "disabled_providers": ["opencode", "openai", "copilot"]
        }
      merge-strategy: json-merge
    execution:
      command-name: opencode
      args:
        - run
        - --print-logs
        - --log-level
        - DEBUG
      step-name: Execute OpenCode CLI
      model-env-var: OPENCODE_MODEL
      mcp-config-env-var: GH_AW_MCP_CONFIG
      write-timestamp: true
      provider-env-mode: universal-llm-consumer
      env:
        XDG_DATA_HOME: /tmp/opencode-data
        # OpenCode installs its built-in auth plugins (e.g.
        # opencode-anthropic-auth) at startup with an unbounded `bun add`,
        # which would hang here because registry.npmjs.org is not in the
        # firewall allowlist. This workflow uses a config-level API key, so the
        # default plugins are not needed.
        OPENCODE_DISABLE_DEFAULT_PLUGINS: "1"
    harness-script: |
      // @ts-check
      // Runtime harness for the OpenCode CLI on a behaviour-defined engine.
      //
      // The static config-file block above intentionally contains no provider:
      // hard-coding one (as the previous definition did with
      // `awf-proxy` + 172.30.0.30:10002 + a fixed model) is what produced
      // `unknown_model_ai_credits` and the 20-minute hang. The AWF api-proxy's
      // provider/model catalog is only known at run time, so this harness
      // discovers the chat endpoint and the available model IDs from the
      // proxy's `/reflect` endpoint and writes a real provider into
      // `opencode.jsonc` before spawning the CLI.
      const { mkdirSync, readFileSync, writeFileSync } = require("fs");
      const { join } = require("path");
      const { spawnSync } = require("child_process");
      const {
        fetchAWFReflect,
        resolveProviderEndpointFromReflect,
        deriveBaseUrlFromModelsURL,
        waitForProviderListenerReady,
      } = require("./awf_reflect.cjs");

      const [command, ...commandArgs] = process.argv.slice(2);
      const log = message => process.stderr.write(`[opencode-harness] ${message}\n`);
      const fail = (result, action) => {
        if (result.error) throw result.error;
        // A process killed by a signal has status === null and a non-null
        // signal, so checking only status would treat a SIGKILL/SIGTERM as
        // success and let the job proceed as if the agent completed.
        if (result.signal) {
          const error = new Error(`${action} was terminated by signal ${result.signal}`);
          error.exitCode = 1;
          throw error;
        }
        if (result.status !== 0) {
          const error = new Error(`${action} failed with exit code ${result.status ?? "unknown"}`);
          error.exitCode = typeof result.status === "number" && result.status !== 0 ? result.status : 1;
          throw error;
        }
      };

      const main = async () => {
        const workspace = process.env.GITHUB_WORKSPACE;
        if (!workspace) throw new Error("GITHUB_WORKSPACE is required");

        const selectedModel = process.env.OPENCODE_MODEL;
        if (!selectedModel || !selectedModel.includes("/")) {
          throw new Error("OPENCODE_MODEL must use provider/model format");
        }
        const model = selectedModel.slice(selectedModel.indexOf("/") + 1);
        if (!model) throw new Error("OPENCODE_MODEL must include a model name");

        const provider = process.env.GH_AW_LLM_PROVIDER;
        if (!provider) throw new Error("GH_AW_LLM_PROVIDER is required");

        // The proxy injects upstream auth; the CLI only needs a non-empty key.
        const configFile = join(workspace, "opencode.jsonc");
        let config = {};
        try {
          config = JSON.parse(readFileSync(configFile, "utf8"));
        } catch (err) {
          if (err.code !== "ENOENT") throw err;
        }
        config.disabled_providers = ["opencode", "openai", "copilot"];

        let baseURL = "";
        let resolvedModel = model;
        if (process.env.AWF_REFLECT_ENABLED === "1") {
          const result = await fetchAWFReflect({ logger: log });
          if (!result.ok || !result.reflectData) {
            throw new Error(`Unable to discover the OpenCode LLM endpoint from /reflect: ${result.reason || "empty response"}`);
          }
          const endpoint = resolveProviderEndpointFromReflect({
            provider,
            reflectData: result.reflectData,
            logger: log,
          });
          if (!endpoint || !endpoint.baseUrl) {
            throw new Error(`No configured /reflect endpoint found for provider ${provider}`);
          }
          baseURL = endpoint.baseUrl;
          const reflectedEndpoint = result.reflectData.endpoints?.find(
            entry => entry?.configured === true && entry.provider === endpoint.endpointProvider
          );
          if (typeof reflectedEndpoint?.models_url === "string") {
            baseURL = deriveBaseUrlFromModelsURL(reflectedEndpoint.models_url);
          }
          // Prefer an advertised model id over the requested one when the proxy
          // exposes a catalog: a model the proxy cannot price is exactly what
          // triggers unknown_model_ai_credits.
          const advertised = Array.isArray(reflectedEndpoint?.models) ? reflectedEndpoint.models.filter(Boolean) : [];
          if (advertised.length > 0 && !advertised.includes(resolvedModel)) {
            const canon = value => String(value).toLowerCase().replace(/\./g, "-");
            const target = canon(resolvedModel);
            const match = advertised.find(id => canon(id) === target)
              || advertised.find(id => canon(id).startsWith(`${target}-`) || target.startsWith(`${canon(id)}-`))
              || advertised.find(id => canon(id).includes(target) || target.includes(canon(id)));
            if (match) {
              log(`model ${resolvedModel} not advertised; using ${match}`);
              resolvedModel = match;
            } else {
              log(`model ${resolvedModel} not advertised (${advertised.length} available); sending as-is`);
            }
          }
          // The proxy port may not accept connections yet; without this wait the
          // CLI connects too early and the step hangs until timeout.
          const listener = await waitForProviderListenerReady({ baseUrl: baseURL, logger: log });
          if (!listener.ok) {
            throw new Error(`api-proxy provider listener not ready at ${baseURL}: ${listener.error}`);
          }
        } else {
          baseURL = process.env.OPENAI_BASE_URL || "";
        }
        if (!baseURL) {
          throw new Error("OpenCode requires AWF endpoint discovery or OPENAI_BASE_URL");
        }

        config.provider = {
          ...(config.provider || {}),
          "awf-proxy": {
            npm: "@ai-sdk/openai-compatible",
            name: "GitHub Agentic Workflows",
            options: { baseURL, apiKey: "awf-proxy" },
            models: { [resolvedModel]: {} },
          },
        };
        writeFileSync(configFile, JSON.stringify(config, null, 2), { mode: 0o600 });

        const promptPath = process.env.GH_AW_PROMPT;
        if (!promptPath) throw new Error("GH_AW_PROMPT is required");
        const prompt = readFileSync(promptPath, "utf8");
        const env = { ...process.env, OPENCODE_MODEL: `awf-proxy/${resolvedModel}` };
        log(`configured provider=${provider} baseURL=${baseURL} model=${resolvedModel}`);
        // Close the child's stdin. The prompt is already passed as an argument,
        // but OpenCode v1.2.14 still does `await Bun.stdin.text()` for
        // non-TTY stdin before bootstrap; with an inherited open pipe that
        // never reaches EOF it blocks forever with no output (upstream bug,
        // opencode#38723). `ignore` maps stdin to /dev/null.
        fail(
          spawnSync(command, [...commandArgs, prompt], { cwd: workspace, env, stdio: ["ignore", "inherit", "inherit"] }),
          "OpenCode execution"
        );
      };

      main().catch(error => {
        log(error instanceof Error ? error.message : String(error));
        process.exitCode = typeof error?.exitCode === "number" && error.exitCode !== 0 ? error.exitCode : 1;
      });
    mcp:
      config-path: opencode.jsonc
      config-adapter: |
        // Converts the MCP gateway's { mcpServers: { name: { url, headers } } }
        // output into OpenCode's native `mcp` schema and merges it into the
        // workspace opencode.jsonc written by the static config-file step.
        // OpenCode reads MCP servers from its own config file (there is no
        // env-var indirection), and CLI-mounted servers (GH_AW_MCP_CLI_SERVERS)
        // are already exposed as `github`/`safeoutputs` executables, so they are
        // filtered out here to avoid duplicate tool surfaces.
        const fs = require("fs");
        const path = require("path");

        const requireEnvVar = name => {
          const value = process.env[name];
          if (!value) throw new Error(`${name} environment variable is required`);
          return value;
        };

        const gatewayOutputPath = requireEnvVar("MCP_GATEWAY_OUTPUT");
        const workspace = requireEnvVar("GITHUB_WORKSPACE");
        const configFile = path.join(workspace, "opencode.jsonc");

        let cliServers;
        try {
          cliServers = new Set(JSON.parse(process.env.GH_AW_MCP_CLI_SERVERS || "[]"));
        } catch (err) {
          throw new Error(`Failed to parse GH_AW_MCP_CLI_SERVERS: ${err instanceof Error ? err.message : String(err)}`);
        }

        const gatewayOutput = JSON.parse(fs.readFileSync(gatewayOutputPath, "utf8"));
        const rawServers = gatewayOutput.mcpServers;
        const servers = rawServers && typeof rawServers === "object" && !Array.isArray(rawServers) ? rawServers : {};

        console.log("Converting gateway configuration to OpenCode format...");
        console.log(`Input: ${gatewayOutputPath}`);
        if (cliServers.size > 0) {
          console.log(`CLI-mounted servers to filter: ${[...cliServers].join(", ")}`);
        }

        const mcp = {};
        for (const [name, entry] of Object.entries(servers)) {
          if (cliServers.has(name)) continue;
          const server = { ...entry };
          delete server.tools;
          mcp[name] = { ...server, type: "remote", enabled: true };
        }

        let config = {};
        try {
          config = JSON.parse(fs.readFileSync(configFile, "utf8"));
        } catch (err) {
          if (err.code !== "ENOENT") throw err;
        }
        config.mcp = { ...(config.mcp || {}), ...mcp };

        // The MCP headers contain the gateway bearer token. OpenCode reads its
        // config from the workspace, which is mounted read/write into the agent
        // container, and the CLI and the agent run as the same user, so 0600
        // does NOT keep the token from the agent process. This mirrors the
        // upstream Goose engine adapter, which also writes the bearer into the
        // agent-readable workspace; gh-aw's declarative engine schema has no
        // out-of-workspace config mount for OpenCode. The token only unlocks the
        // gateway, which enforces the same tool guard policies as the MCP tools.
        fs.writeFileSync(configFile, JSON.stringify(config, null, 2), { mode: 0o600 });
        fs.chmodSync(configFile, 0o600);
        console.log(`Servers: ${Object.keys(mcp).length} included, ${Object.keys(servers).length - Object.keys(mcp).length} filtered (CLI-mounted)`);
        console.log(`OpenCode configuration written to ${configFile}`);
    log-parser: |
      function parseLog(logContent) {
        const lines = logContent.split("\n");
        const logEntries = [];
        const mcpFailures = [];
        let maxTurnsHit = false;
        const AWF_INFRA_RE = /^\[(INFO|WARN|SUCCESS|ERROR|entrypoint|health-check)\]|^ (?:Container|Network|Volume) |^Process exiting with code:/;
        let inputTokens = 0;
        let outputTokens = 0;
        let toolCallIndex = 0;
        let turnCount = 0;
        let pendingText = [];

        function flushText() {
          if (pendingText.length === 0) return;
          const text = pendingText.join("\n").trim();
          if (text) {
            logEntries.push({ type: "assistant", message: { content: [{ type: "text", text }] } });
            turnCount++;
          }
          pendingText = [];
        }

        logEntries.push({ type: "system", subtype: "init", model: null, session_id: null });

        for (const line of lines) {
          if (!line.trim()) continue;
          if (AWF_INFRA_RE.test(line)) continue;
          if (/max.?turns|maximum.*turns.*reached|turn limit/i.test(line)) maxTurnsHit = true;
          if (/MCP server .* failed|MCP.*connection.*error|Failed to connect to MCP/i.test(line)) {
            const serverMatch = line.match(/MCP server ['"]?([^\s'"]+)['"]?/i);
            mcpFailures.push(serverMatch ? serverMatch[1] : line.trim());
          }

          let parsed = null;
          try {
            if (line.trim().startsWith("{")) parsed = JSON.parse(line.trim());
          } catch (e) { /* not JSON */ }

          if (parsed) {
            const entryType = parsed.type != null ? String(parsed.type) : "log";
            const msg = parsed.msg || parsed.message || "";
            if (parsed.input_tokens) inputTokens += parsed.input_tokens;
            if (parsed.output_tokens) outputTokens += parsed.output_tokens;

            if (/tool[._]call|tool[._]use/i.test(entryType)) {
              flushText();
              const toolId = `opencode_tool_${toolCallIndex++}`;
              const toolName = parsed.tool || parsed.name || entryType;
              logEntries.push({ type: "assistant", message: { content: [{ type: "tool_use", id: toolId, name: toolName, input: {} }] } });
              logEntries.push({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: toolId, content: msg }] } });
            } else if (msg) {
              pendingText.push(msg);
            }
          } else {
            pendingText.push(line.trim());
          }
        }
        flushText();

        const usage = {};
        if (inputTokens) usage.input_tokens = inputTokens;
        if (outputTokens) usage.output_tokens = outputTokens;
        logEntries.push({ type: "result", num_turns: turnCount, usage });
        const parts = [`**Turns:** ${turnCount}`, `**Tool calls:** ${toolCallIndex}`];
        if (inputTokens || outputTokens) parts.push(`**Tokens:** ${((inputTokens ?? 0) + (outputTokens ?? 0)).toLocaleString()}`);
        if (mcpFailures.length) parts.push(`**MCP failures:** ${mcpFailures.length}`);
        if (maxTurnsHit) parts.push("**Max turns reached**");
        return { markdown: parts.join(" · "), logEntries, mcpFailures, maxTurnsHit };
      }
---

<!--
# OpenCode CLI

Shared engine definition for the [OpenCode](https://opencode.ai) multi-provider AI
coding agent (BYOK). Import this file and set `engine: opencode` to use it:

```yaml
engine:
  id: opencode
model: copilot/claude-sonnet-4.5
imports:
  - shared/opencode.md
```

`model` must use `provider/model` format. Supported providers are `copilot`,
`anthropic`, `openai`, and `codex`.
-->
