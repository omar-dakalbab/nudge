# LinkedIn Post

I just open-sourced **nudge** — an AI-powered terminal monitor for macOS that sends you smart native notifications when things happen in your terminal.

If you've ever stared at a terminal waiting for a build to finish, missed a sudo prompt, or forgot that Claude Code was waiting for your approval — nudge fixes that.

**What it does:**
- Detects when long-running commands finish (builds, deploys, tests)
- Catches processes waiting for your input (sudo, SSH, y/n prompts)
- Monitors Claude Code sessions and notifies you when an agent needs approval
- Uses Apple's built-in NaturalLanguage framework to analyze output and give you smart notifications — no API keys, no costs

Instead of "Process 1234 has completed", you get:
- ❌ swift failed: No such module 'UserAuth'
- ✅ make succeeded: Build complete! (2.3s)
- ⚠️ npm warning: deprecated package xyz
- 🤖 Claude Code needs your approval

**Built with:**
- Swift + Apple NaturalLanguage framework for on-device AI
- Zero external dependencies
- Works as a CLI or macOS menu bar app
- Reads Claude Code session files directly for accurate detection

**Install in one line:**
brew tap omar-dakalbab/nudge && brew install nudge

The AI runs entirely on your Mac using CoreML — no data leaves your machine, no API costs, no setup.

Check it out: https://github.com/omar-dakalbab/nudge

#opensource #developer #tools #ai #macos #swift #terminal #claudecode #productivity
