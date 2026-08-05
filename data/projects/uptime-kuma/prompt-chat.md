<!-- DRAFT — not yet style-guide compliant, not verified -->

<!--
  First-pass chat fallback for people who only have ChatGPT or Claude.ai in a
  browser — no agent, no terminal access from the model. Slower on purpose: you
  are the one running the commands. Phase 1 rewrites it to the style guide.
-->

I want to self-host Uptime Kuma — an uptime monitor with status pages — on a VPS I rent, and I have never administered a server before. Walk me through it one step at a time.

**Here is my situation.** I have a VPS running Ubuntu 24.04. I can open a terminal and SSH into it. Docker and the compose plugin are installed. I own a domain and can add DNS records. I have not installed anything else.

**How I want you to work with me:**

- One step per message. Give me the exact command to paste, tell me what output means it worked, then wait for me to come back before the next step.
- If my output does not match what you expected, help me read the actual error before moving on. Do not guess and continue.
- Explain what each command changes on my machine in one sentence, before I run it. I want to understand what I am running, not just run it.
- Never ask me to paste the contents of `.env` or any credential into this chat.

**What I want at the end:**

- Uptime Kuma reachable at a hostname I choose, over HTTPS, with a certificate that renews itself.
- Caddy in front of it. The app itself not listening on any public port.
- The data directory on local disk, because the history lives in SQLite and needs real file locks.
- My admin account created immediately, since the setup page is open to anyone until it exists.
- One monitor configured, and one deliberately failing monitor so I can prove my notifications actually arrive.
- A backup taken with the container stopped, plus a nightly job I understand well enough to fix.

**Two things I want you to be honest with me about:**

1. This monitor runs on a server. Tell me what happens to my alerts when that server is the thing that is down, and what to do about it.
2. Tell me what I am giving up versus a paid monitoring service, in plain terms, before we start — not after.

**Start by telling me what to check before we install anything** — whether my DNS record is pointing at the right IP, and how to confirm it from my own machine.

Please use pinned image versions in anything you write for me, never a moving tag, and tell me how I upgrade later.
