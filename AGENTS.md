<!-- atlas:start -->
## Atlas
This project is managed by Atlas. Read `atlas/ATLAS.md` first, then `Config/GLOBAL.md` in the Atlas workspace.

Evidence Gate, before every commit and before ending the session:
1. Run the relevant DoD checks and write proof under `atlas/evidence/`.
2. Update `atlas/ATLAS.md`: Status, Last Failure, Next Steps, Blockers.
3. Commit as `type(scope): description - evidence: <path>`.
4. End your reply with: `Evidence: <paths> | Pass N | Fail N | Unverified N`.

Work on `atlas/<feature>` branches; never push to `dev` or `main`. Never delete anything without the user's explicit consent.
<!-- atlas:end -->
