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

## 5. Turning It Off

- **Per family**: toggle **Auto-link receipts** off under **Settings → Receipts → Receipt
  matching** — this stops both the drawer's on-demand scan and the nightly job from touching that
  family, without deleting any existing links.
- **Disconnect entirely**: **Settings → Receipts → Danger zone → Disconnect**. Existing receipt
  links are kept, but no new matching occurs.

## Notes for Contributors

- The per-family connection is `PaperlessConnection` — **not** `PaperlessItem`, unlike the naming
  convention used by most other provider integrations (`PlaidItem`, `RedbarkItem`, etc.).
- `Transaction#receipt_scanned_at` distinguishes "checked, nothing found" from "never checked" —
  it's what lets the nightly job skip already-scanned transactions cheaply.
- See `app/models/provider/paperless.rb` for the API client and `app/models/paperless_connection/matcher.rb`
  for the scoring logic.
