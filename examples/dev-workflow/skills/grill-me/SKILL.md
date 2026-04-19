# Grill Me

Use the provided description, optional PRD text, optional spec text, prior user
answers, and optional approval feedback to build shared understanding for a
software task.

Return a typed planning result with:

- a complete `requirements_document` when enough information is available
- `readiness = NeedsUserAnswers` and the highest-priority `open_questions` when
  important decisions are still unresolved
- `readiness = ReadyForApproval` plus a concise `approval_summary` when the plan
  is ready for sign-off

Keep `open_questions` concrete and actionable. Treat `approval_feedback` as the
latest user feedback and revise the plan before deciding whether it is ready for
approval.
