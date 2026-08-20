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

- When you open a transaction's receipt drawer for the first time, Sure searches Paperless for
  documents near that transaction's date and scores each one on amount, date proximity, and
  correspondent similarity.
- If exactly one document clears the auto-link threshold, it's linked automatically. Otherwise,
  candidates are shown as suggestions you can confirm or dismiss.
- You can also search Paperless manually and link a specific document from the drawer.
- A nightly job (`PaperlessScanAllJob`, `40 3 * * *`, see `config/schedule.yml`) re-scans any
  transaction that hasn't been checked yet (`receipt_scanned_at` is null) across every family with
  a configured connection.

## 5. Reviewing Matches and Scanning On Demand

Once a connection is configured, a **Receipts** entry appears in the main navigation (and a
**Review matches** link under **Settings → Receipts → Receipt matching**). That page lists every
match for your family, newest first:

- Filter by status — **Linked** (the default), **Suggested**, **Dismissed**, or **All** — and by
  how the match was made, **Automatic** or **Manual**. The filters live in the URL, so a filtered
  view is shareable and bookmarkable.
- Each row is a table row: the Paperless document (thumbnail, title, date, and structured amount
  when a custom field is mapped), the **Recipient** (the document's Paperless correspondent) in its
  own column, the transaction it was matched to, and the match status with the reasons it scored on.
- Act on a match without leaving the page: **confirm** a suggestion, **dismiss** it, or **remove**
  the link entirely. The list re-renders itself through the filters you're currently viewing, so a
  confirmed suggestion drops out of a "Suggested" list on the spot. A dismissed match can be
  confirmed later — it stays visible under the **Dismissed** filter.
- The eye button previews the document in a modal without opening Paperless.

**Scan for receipts** starts a family-wide scan immediately instead of waiting for the nightly run.
Progress updates live — no page reload — and is shared by every open tab, because the job pushes it
over the family's Turbo Stream.

A few things worth knowing about a manual scan:

- It covers the same transactions the nightly job would: entry date within the last 90 days,
  excluding transfers, and either never scanned or last scanned more than 7 days ago with nothing
  linked yet.
- It processes at most 500 transactions per run. If you have a larger backlog the run reports that
  it stopped at the cap; scan again to continue through it.
- **It runs even when Auto-link receipts is off.** That toggle governs the nightly job; pressing
  the button is explicit intent. This matches the per-transaction "find again" action in the
  receipt drawer, which has always behaved the same way.
- Only one scan runs per family at a time. Pressing the button during a run just shows you the run
  already in progress.
- Transactions that error out individually are counted and recorded in the super-admin
  **Settings → Debug** log (category `provider_sync`, provider `paperless`); the scan keeps going.
  A scan aborts early if Paperless rejects the API token or fails five times in a row.

## 6. Turning It Off

- **Per family**: toggle **Auto-link receipts** off under **Settings → Receipts → Receipt
  matching** — this stops both the drawer's on-demand scan and the nightly job from touching that
  family, without deleting any existing links. Manual scans from the Receipts page still run.
- **Disconnect entirely**: **Settings → Receipts → Danger zone → Disconnect**. Existing receipt
  links are kept, but no new matching occurs.

## Notes for Contributors

- The per-family connection is `PaperlessConnection` — **not** `PaperlessItem`, unlike the naming
  convention used by most other provider integrations (`PlaidItem`, `RedbarkItem`, etc.).
- `Transaction#receipt_scanned_at` distinguishes "checked, nothing found" from "never checked" —
  it's what lets the nightly job skip already-scanned transactions cheaply.
- A family-wide scan is one `PaperlessScan` row plus one sequential `PaperlessScanFamilyJob`, which
  reports progress onto that row and broadcasts `receipts/_scan_status` to the family stream. It
  runs sequentially rather than fanning out per transaction so it can report progress at all, and
  so it reuses a single `Matcher` (whose `correspondents` / `custom_fields` are memoized per
  instance). Because that partial renders in a job as well as a request, it must not read
  `Current.*` and must use absolute i18n keys.
- A partial unique index on `paperless_scans.family_id` (where status is `pending`/`running`)
  enforces one live scan per family. `PaperlessScan#stale?` covers a job that died mid-run.
- `ReceiptLink#confirm!` / `#dismiss!` are the one definition of those two decisions, shared by the
  drawer (`ReceiptLinksController`) and the list (`Receipts::LinksController`). The two controllers
  render completely different things, so they share the *scope* instead via the
  `ReceiptLinkListing` concern — a mutation always re-queries through the filters the user is
  looking at, which is why row actions carry `status`/`source`/`page`.
- See `app/models/provider/paperless.rb` for the API client and `app/models/paperless_connection/matcher.rb`
  for the scoring logic.
