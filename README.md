# ControlTheory Installers

Public install scripts for deploying the **ControlTheory agent** into your own
**Kubernetes** cluster or **Docker** host, so runtime telemetry flows into
[Dstl8](https://dstl8.ai).

> Served at **[install.controltheory.com](https://install.controltheory.com)** — this is the code behind the `curl … | bash` command Dstl8 gives you when you add a Kubernetes or Docker source.

## What is Dstl8?

**Dstl8** is continuous runtime feedback for developers. It distills, detects,
correlates, and explains problems across your full deployment chain —
Kubernetes, Docker, AWS, Vercel, Supabase, Railway, OpenTelemetry, and more —
so you stay out of debug rabbit holes. Powered by Möbius agents, an MCP server,
and the Dstl8 CLI, that context streams back into Claude Code, Cursor, and the
rest of your dev flow.

- Website — **[dstl8.ai](https://dstl8.ai)** · [controltheory.com](https://www.controltheory.com)
- Documentation — **[docs.controltheory.com](https://docs.controltheory.com/controltheory-documentation/dstl8-docs)**
- Dstl8 CLI — **[github.com/control-theory/dstl8](https://github.com/control-theory/dstl8)**

## Getting started

New to Dstl8? Start here — you don't need this repo to begin.

1. **Sign up** and grab the Dstl8 CLI:
   ```bash
   brew install control-theory/dstl8/dstl8
   dstl8 signup
   ```
2. **Add a source** so logs start flowing. The CLI wizard covers Kubernetes,
   CloudWatch, Vercel, Supabase, OTLP, GitHub, and more:
   ```bash
   dstl8 sources add kubernetes
   ```
3. **Connect your AI agent** over MCP:
   ```bash
   dstl8 install claude-code
   ```

Full walkthrough in the [Dstl8 CLI repo](https://github.com/control-theory/dstl8)
and the [docs](https://docs.controltheory.com/controltheory-documentation/dstl8-docs).

## When to use these scripts

Some environments run an in-cluster/on-host agent to collect logs and events
directly from the source. That's what this repo installs:

| Platform | What it deploys |
|----------|-----------------|
| **Kubernetes** | Helm charts for the aigent DaemonSet (node log collection) and cluster agent (Kubernetes events) |
| **Docker** | The `controltheory/aigent` container, wired to the Docker socket and host logs |

The installer is driven by tokens and endpoints that Dstl8 generates for you.
The easiest path is to **add a Kubernetes or Docker source in the
[Dstl8 app](https://dstl8.ai)** — it hands you the exact `curl … | bash`
command, pre-filled, to paste into your terminal. See the
[installation docs](https://docs.controltheory.com/controltheory-documentation/dstl8-docs)
for details.


## Contributing

These scripts are published from this repo via GitHub Pages. Changes are tested
on `stage` and released through `main` — see [CONTRIBUTING.md](CONTRIBUTING.md)
for the branching and release workflow.

## Community & support

- 💬 [Discord](https://discord.gg/nRBUFYByta)
- 🐛 [Issues](https://github.com/control-theory/dstl8/issues)

## License

The installer scripts in this repository are MIT licensed. The ControlTheory
agent and Dstl8 binaries themselves are proprietary, owned by ControlTheory,
Inc., and governed by the
[ControlTheory Terms of Service](https://www.controltheory.com/terms-of-service/).
