# Setting Up Paperless-ngx Receipt Matching

Sure can link your transactions to receipts and invoices stored in a [Paperless-ngx](https://docs.paperless-ngx.com/)
instance you already run — Paperless stays the source of truth for the documents; Sure never
copies them in, it only reads from Paperless's API and proxies thumbnails/previews/downloads
through your own server.

## 1. Mint a Paperless API Token

1. In Paperless-ngx, go to your user icon (top right) → **My Profile**.
2. Under **Auth Token**, click the button to create a token (or copy the existing one).
3. Copy the token — you'll paste it into Sure in the next step.

## 2. Connect Sure to Paperless

1. In Sure, go to **Settings → Receipts** (admin only).
2. Enter your Paperless instance's URL (e.g. `https://paperless.example.com`) and paste the API
   token from step 1.
3. If your instance uses a self-signed TLS certificate, turn off **Verify SSL certificate**.
4. Click **Test connection** — it should report the number of documents found in your instance.

## 3. (Optional) Map Custom Fields

If you've set up Paperless [custom fields](https://docs.paperless-ngx.com/usage/#custom-fields) —
for example via AI-assisted document parsing — to capture a document's total, net, tax, or
invoice/reference number, a **Custom fields** section appears on the same settings page once
you're connected. Map each role to the corresponding Paperless field (Sure guesses reasonable
defaults from the field names, but the choice is always yours to correct). This is entirely
optional: matching still works from the document's OCR text alone when nothing is mapped.

## 4. How Matching Works

Matching runs in two directions, because they cover different situations:

- **Transaction → document** (the original direction): when you open a transaction's receipt
  drawer for the first time, Sure searches Paperless for documents near that transaction's date and
  scores each one on amount, date proximity, and correspondent similarity. A nightly job
  (`PaperlessScanAllJob`, `40 3 * * *`, see `config/schedule.yml`) re-scans any transaction that
  hasn't been checked yet (`receipt_scanned_at` is null) across every family with a configured
  connection. This direction is naturally recent-transaction-shaped: it only ever looks at
  transactions from the last 90 days.
- **Document → transaction**: walks Paperless's documents instead, newest-added first, and searches
  your *local* transactions for each one by amount/date/correspondent. This is what finds a receipt
  for an old transaction — a scanned invoice filed away months after the purchase, or a backlog of
  historical receipts uploaded to Paperless all at once — that the transaction-first direction would
  never revisit. See **Matching a Backlog of Old Receipts** below.

Both directions score the same way and land on the same decision: if exactly one document clears
the auto-link threshold, it's linked automatically; otherwise, candidates are shown as suggestions
you can confirm or dismiss. You can also search Paperless manually and link a specific document
from the drawer.

## 5. Reviewing Matches and Scanning On Demand

Once a connection is configured, a **Receipts** entry appears in the main navigation (and a
**Review matches** link under **Settings → Receipts → Receipt matching**). That page lists every
match for your family, newest first:

- Filter by status — **Linked** (the default), **Suggested**, **Dismissed**, or **All** — and by
  how the match was made, **Automatic** or **Manual**. The filters live in the URL, so a filtered
  view is shareable and bookmarkable.
- Each row is a table row: the Paperless document (thumbnail, title, correspondent, date, and
  structured amount when a custom field is mapped), the **Recipient** (the matched transaction's
  merchant) in its own column, the transaction itself, and the match status with the reasons it
  scored on.
- Act on a match without leaving the page: **confirm** a suggestion, **dismiss** it, or **remove**
  the link entirely. The list re-renders itself through the filters you're currently viewing, so a
  confirmed suggestion drops out of a "Suggested" list on the spot. A dismissed match can be
  confirmed later — it stays visible under the **Dismissed** filter.
- The eye button previews the document in a modal without opening Paperless.

Two buttons sit above the list, one per matching direction:

- **Scan recent transactions** starts a family-wide transaction-first scan immediately instead of
  waiting for the nightly run.
- **Match unlinked receipts** starts a family-wide document-first sweep — see the next section.

Progress for whichever one is running updates live — no page reload — and is shared by every open
tab, because the job pushes it over the family's Turbo Stream. Only one run (of either kind) goes
at a time per family; the other button is disabled while one is in progress, and pressing a button
during a run just shows you the run already in progress.

A few things worth knowing about a manual transaction scan:

- It covers the same transactions the nightly job would: entry date within the last 90 days,
  excluding transfers, and either never scanned or last scanned more than 7 days ago with nothing
  linked yet.
- It processes at most 500 transactions per run. If you have a larger backlog the run reports that
  it stopped at the cap; scan again to continue through it.
- **It runs even when Auto-link receipts is off.** That toggle governs the nightly job; pressing
  the button is explicit intent. This matches the per-transaction "find again" action in the
  receipt drawer, which has always behaved the same way.
- Transactions that error out individually are counted and recorded in the super-admin
  **Settings → Debug** log (category `provider_sync`, provider `paperless`); the scan keeps going.
  A scan aborts early if Paperless rejects the API token or fails five times in a row.

## 6. Matching a Backlog of Old Receipts

If you've just uploaded — or bulk-imported — a batch of old receipts to Paperless, the
transaction-first scan above will never find them: it only looks at transactions from the last 90
days, and once a transaction has been checked it isn't revisited unless it's still inside that
window. **Match unlinked receipts** on the Receipts page is built for exactly this: it walks
Paperless's documents instead (newest-uploaded first) and searches your existing transactions for
each one, so it doesn't matter how old the transaction is or how long ago the receipt was actually
purchased — only how far apart their dates are, controlled by **Receipt sweep window (days)** under
**Settings → Receipts → Receipt matching** (30 days by default; a receipt filed further from its
transaction date than that won't be found this way).

A nightly job (`PaperlessSweepAllJob`, `10 4 * * *`) also runs this direction automatically, but
bounded to documents added to Paperless in roughly the last two weeks — enough to catch normal
day-to-day filing without re-walking your whole archive every night. A one-off bulk upload of much
older receipts needs the manual button at least once; after that, the nightly sweep keeps up on its
own.

**You do not need to track which documents have already been checked.** A document that's already
`linked` is skipped automatically (that link *is* the record that it's been handled), and a
document that matched nothing is simply looked at again next time — that's a cheap local database
query, not another Paperless API call, so re-running the sweep costs almost nothing. A suggestion
you've dismissed also never comes back automatically. In short: running the sweep once, or every
night, or both, all converge to the same result — feel free to press the button as often as you
like.

**A confident amount match plus an exact or near-exact date auto-links even with no correspondent
match at all.** Without mapped custom fields, the OCR-only amount signal is worth `0.45` and an
exact-date match is worth `0.25` — `0.45 + 0.25 = 0.70`, exactly the default **Minimum auto-link
score** — so correspondent similarity (`0.20`) is a bonus that helps a slightly-off date still clear
the bar, not a hard requirement. A backlog run can still produce plenty of suggestions rather than
automatic links — a document a few days off from its transaction, or with an amount that doesn't
appear verbatim in the OCR text, won't reach `0.70` on its own — and reviewing/confirming those on
the Receipts page is the normal way to work through the rest of a backlog. Raising or lowering
**Minimum auto-link score** trades off how aggressively Sure auto-links against the risk of a wrong
match.

## 7. Turning It Off

- **Per family**: toggle **Auto-link receipts** off under **Settings → Receipts → Receipt
  matching** — this stops the drawer's on-demand scan and both nightly jobs from touching that
  family, without deleting any existing links. Manual scans and sweeps from the Receipts page still
  run.
- **Disconnect entirely**: **Settings → Receipts → Danger zone → Disconnect**. Existing receipt
  links are kept, but no new matching occurs.

## Notes for Contributors

- The per-family connection is `PaperlessConnection` — **not** `PaperlessItem`, unlike the naming
  convention used by most other provider integrations (`PlaidItem`, `RedbarkItem`, etc.).
- `Transaction#receipt_scanned_at` distinguishes "checked, nothing found" from "never checked" —
  it's what lets the nightly transaction scan skip already-scanned transactions cheaply. The
  document-first sweep deliberately never touches this column: it only ever looks at the
  transactions inside one document's date window, not a transaction's full candidate set, so
  stamping it there would incorrectly suppress the transaction-first scan.
- A family-wide run is one `PaperlessScan` row (`mode`: `transactions` or `documents`) plus one
  sequential job — `PaperlessScanFamilyJob` or `PaperlessSweepDocumentsJob` — which reports progress
  onto that row and broadcasts `receipts/_scan_status` to the family stream via the shared
  `PaperlessScanReporting` concern (`app/jobs/concerns/`). Both run sequentially rather than fanning
  out per item so they can report progress at all, and so each reuses a single matcher instance
  (whose `correspondents` / `custom_fields` are memoized per instance). Because that partial renders
  in a job as well as a request, it must not read `Current.*` and must use absolute i18n keys.
- A partial unique index on `paperless_scans.family_id` (where status is `pending`/`running`)
  enforces one live run per family, regardless of mode. `PaperlessScan#stale?` covers a job that
  died mid-run.
- Matching runs in both directions from the same scoring rules, in
  `PaperlessConnection::Scoring` (shared amount/date/correspondent weights and `persist_link`):
  `PaperlessConnection::Matcher` (transaction → candidate documents, the original direction) and
  `PaperlessConnection::DocumentMatcher` (document → candidate transactions, added for backlog
  sweeps). `DocumentMatcher` additionally requires an amount signal on every candidate, since it
  searches across the whole family rather than one already-known transaction — without that,
  date+correspondent alone would surface every nearby transaction as noise.
- `ReceiptLink#confirm!` / `#dismiss!` are the one definition of those two decisions, shared by the
  drawer (`ReceiptLinksController`) and the list (`Receipts::LinksController`). The two controllers
  render completely different things, so they share the *scope* instead via the
  `ReceiptLinkListing` concern — a mutation always re-queries through the filters the user is
  looking at, which is why row actions carry `status`/`source`/`page`.
- See `app/models/provider/paperless.rb` for the API client and
  `app/models/paperless_connection/scoring.rb` for the scoring logic shared by both matchers.
