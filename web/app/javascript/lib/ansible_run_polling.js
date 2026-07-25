export const TERMINAL_RUN_STATUSES = new Set(["succeeded", "failed", "partially_succeeded", "canceled"])

export function terminalRunStatus(status) {
  return TERMINAL_RUN_STATUSES.has(String(status))
}

export class PollFailures {
  constructor(maximum = 3) {
    this.maximum = maximum
    this.count = 0
  }

  recordFailure() {
    this.count += 1
    return this.count >= this.maximum
  }

  recordSuccess() {
    this.count = 0
  }
}
