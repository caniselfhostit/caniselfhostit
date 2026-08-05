<!-- DRAFT — not yet style-guide compliant, not verified -->

<!--
  First-pass chat fallback for people who only have ChatGPT or Claude.ai in a
  browser — no agent, no terminal access from the model. Slower on purpose: you
  are the one running the commands. Phase 1 rewrites it to the style guide.
-->

I want to self-host Vaultwarden — a Bitwarden-compatible password server — on a VPS I rent, and I have never administered a server before. Walk me through it one step at a time.

**Here is my situation.** I have a VPS running Ubuntu 24.04. I can open a terminal and SSH into it. Docker and the compose plugin are installed. I own a domain and can add DNS records. I have not installed anything else.

**How I want you to work with me:**

- One step per message. Give me the exact command to paste, tell me what output means it worked, then wait for me to come back before the next step.
- If my output does not match what you expected, help me read the actual error before moving on. Do not guess and continue.
- Never ask me to paste a password, a token, or the contents of `.env` into this chat. If you need to know whether something worked, tell me what to check on my own screen.
- Explain what each command changes on my machine in one sentence, before I run it. I want to understand what I am running, not just run it.

**What I want at the end:**

- Vaultwarden reachable at a hostname I choose, over HTTPS, with a certificate that renews itself.
- Caddy in front of it. The app itself not listening on any public port.
- Registration turned off after I have made my own account, so nobody else can sign up.
- The admin passphrase generated on the server, not in this chat.
- A backup of the data directory taken before we finish, and an honest explanation of why a backup sitting on the same server is not really a backup.
- A short list of what I now own: the updates, the backups, and the recovery.

**Start by telling me what to check before we install anything** — whether my DNS record is pointing at the right IP, and how to confirm it from my own machine.

Please use pinned image versions in anything you write for me, never a moving tag, and tell me how I upgrade later.
