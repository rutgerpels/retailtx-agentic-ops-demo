---
applyTo: "**/*"
---

# Developer Flow

The default handoff is a pull request for human review, not an issue requiring the user to manage implementation.

1. Check relevant existing GitHub issues and dependencies before starting. An issue is not a prerequisite for authorized work; do not create routine implementation-tracking issues unless explicitly requested.
2. Work on a dedicated branch, never directly on `main`. Reuse the app-managed feature branch in an existing worktree session. Otherwise create a branch named `Feature/<short-description-of-feature>` or `Bug/<short-description-of-bug>`.
3. Implement and validate the requested work, then open a pull request targeting `main` for human review. Update the existing PR when continuing the same work rather than opening a duplicate.
4. Raise a GitHub issue when the user needs to take action beyond normal PR review, such as resolving a decision, granting access, or completing a manual prerequisite. State the exact action needed, why it is needed, the recommended resolution where appropriate, and what is blocked. Follow the repository's Agile issue requirements.
5. At handoff, explicitly state what is pending the user's action, with links to the PR and any action-required issues. Distinguish PR review from other actions; say when there are no additional actions. Do not present routine implementation work as the user's responsibility.
6. Maintain existing linked issues and board status without asking the user to do administrative updates. Use In Progress while implementing and Review when available. If the board lacks Review, explain the pending review without marking the issue Done. Close the issue and move it to Done only after its acceptance criteria are met and the relevant changes are reviewed, approved, and merged.

# Rules

- Never commit directly to main
- You can not approve the pull request, this has to be done by a human unless specificly told otherwise by a human.