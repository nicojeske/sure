# Sure (fork)

Personal-finance app for a family: accounts, transactions, budgets, rules and bills, with an AI-assisted monthly review of every transaction.

## Monthly review

**Monthly review**:
The family's pass over one budget month, going through its transactions one at a time until each is reviewed.
_Avoid_: Month review, monthly check

**Reviewed transaction**:
A transaction someone has confirmed during a monthly review; a later change to its amount or date makes it unreviewed again.
_Avoid_: Checked, approved

**Year view**:
The monthly review overview for one calendar year, listing that year's budget months with their review progress.
_Avoid_: Rolling window, archive

**Hint**:
Short free text a reviewer types on a transaction to steer the AI (e.g. "Apfelentkerner + Handwärmer", "make this a rule").
_Avoid_: Prompt, note

**Receipt**:
A Paperless-ngx document linked to a transaction; shown to the reviewer as the document itself, read by the AI only as text.
_Avoid_: Attachment, document (when the link is meant)

## Rules and suggestions

**Rule-handled transaction**:
A transaction with at least one field set by a rule.
_Avoid_: Auto-categorized, ruled

**Rule-set field**:
A transaction field whose current value was set by a rule; the AI leaves it alone unless the reviewer's hint asks otherwise.

**Rule suggestion**:
A proposed new rule shown during review, either derived from a repeating pattern in reviewed transactions or asked for in a hint. It is never created without the reviewer's confirmation.
_Avoid_: Auto-rule, rule recommendation

**Bill suggestion**:
A prompt during review to confirm or create a bill for a transaction that belongs to a recurring series.
_Avoid_: Recurring suggestion, subscription suggestion

**Bill**:
A recurring series of expected payments (bill, subscription, installment, …) that transactions are matched against.
_Avoid_: Recurring transaction (in user-facing language)

## AI

**AI content language**:
The family-wide language the AI writes stored values in (names, notes, new tags and merchants), independent of each user's interface language.
_Avoid_: LLM language, AI locale
