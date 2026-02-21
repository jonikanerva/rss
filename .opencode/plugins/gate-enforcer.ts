export const GateEnforcer = async () => ({
  "tool.execute.before": async (input: any, output: any) => {
    if (input.tool === "bash") {
      const cmd = String(output.args?.command || "")
      if (cmd.startsWith("git push")) throw new Error("Blocked: git push requires manual path")
      if (cmd.includes("rm -rf")) throw new Error("Blocked: destructive command")
    }
  }
})
