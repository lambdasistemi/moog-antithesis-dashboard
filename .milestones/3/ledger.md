# Reliable dashboard collection — milestone 3

Recovered 2026-10-12 on explicit operator instruction: resurrect milestone and epic in this tmux lane. Home: lambdasistemi/moog-antithesis-dashboard. Architecture epic #14 previously had no milestone, ledger or identified live owner. Milestones 1 (GitHub report access) and 2 (Wallet balances and spending) remain separate; this owner holds milestone 3 only.

## Product outcome

The deployed public dashboard refreshes from a CI-built container collector without SSH, consumes pushed agent/oracle/freshness status, keeps stale-source behavior and refuses secret publication. Parent acceptance requires deployed stop/restart controls and evidence for every secret boundary; hosted CI alone is insufficient.

## Owner and roster

This existing Codex conversation is the milestone owner at pane %36, session id $7, window id @10. Runtime: /home/paolino/.orch-runtime/moog-antithesis-dashboard/milestone-3/. A separate epic-owner seat is proposed using the same Codex configuration (gpt-6.1-sol, medium as observed in current config); its approval is pending. No ticket, implementation or audit seat is authorized by this recovery. Roster decision must precede launch.

## Preserved epic and candidates

Epic #14: Containerized collector with push-based host status. Serial dependency and merge order: #10 → #11 → #12 → #13. Candidate branches/worktrees preserved; no code changes, merges, deployments or fresh acceptance execution performed by the desk.

| Ticket | PR | Exact head | Worktree | State |
|---|---|---|---|---|
| #10 | #15 | aaee582f60b445f74e901ff2215cbfb4c5a59085 | /code/moog-antithesis-dashboard-issue-10 | Open; hosted checks successful; acceptance not recovered |
| #11 | #17 | 9675d291ba3706b84e2443fdcb4ffd0be524e8b6 | /code/moog-antithesis-dashboard-issue-11 | Draft; hosted checks successful; acceptance not recovered |
| #12 | #18 | 6f9f2f5ff92f0d9233a48e81adc6990a4d5ffcea | /code/moog-antithesis-dashboard-issue-12 | Draft; hosted checks successful; acceptance not recovered |
| #13 | #19 | d8ea0e22d255a3cf0d136fb32feaa2edfc2406e2 | /code/moog-antithesis-dashboard-issue-13 | Draft; hosted checks successful; acceptance not recovered |

Fresh API snapshot: evidence/open-prs.json and evidence/issues.json in the runtime. The check results were fetched 2026-10-12 and refer to historical hosted execution at those candidate heads, not fresh independent execution.

## Priorities and parked decisions

1. Recover epic ownership and reconcile evidence and residuals for #10/PR15.
2. Preserve serial merge order before release of downstream integration.
3. Resolve deployment/secret inventories and live evidence through ticket owners after staffing is authorized.

Open decision: recovery roster, separate epic owner or explicitly compact coordination. No prior staffing contract was found. Other owners and PRs (#16 favicon, #21 property chip) remain outside this scope. Product requests #22–#24 stay in their own milestones.

## Next action

Receive the operator's roster answer, record it, then dispatch only the approved epic recovery seat or record the approved compact role. Recover candidates, do not rebuild the team from assumptions.

## Wiki projection

WIKI SYNC BLOCKED: wiki Git repository returned Repository not found on 2026-10-12; no last verified publication exists. Pending register Milestone-3-Stories.json and generated Milestone-3.md are retained in the runtime.
