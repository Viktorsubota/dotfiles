// tmux agent-state adapter for opencode (tmux/agents/SPEC.md).
// Install: cp into ~/.config/opencode/plugins/ (uninstall.sh removes it).
export const TmuxAgentState = async ({ $ }) => {
  const home = process.env.HOME
  const script = `${process.env.DOTFILES_DIR ?? home + "/dotfiles"}/tmux/agents/agent-state.sh`
  const send = async (ev) => {
    try {
      await $`${script} ${ev} opencode`.quiet()
    } catch {}
  }
  return {
    event: async ({ event }) => {
      if (!process.env.TMUX_PANE) return
      if (event.type === "permission.asked") await send("action")
      else if (event.type === "session.idle") await send("stop")
      else if (event.type === "tool.execute.before") await send("running")
    },
  }
}
