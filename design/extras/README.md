# Basecamp Extras listing

Artifacts for submitting Send Invoice to https://basecamp.com/extras
(the listing is added via a pull request to Basecamp's public `extras` repo).

## Files here
- `send-invoice.png` — the app icon, **256×256 PNG** (meets the Extras requirement).
- `integrations-entry.yml` — the block to paste into the repo's `integrations.yml`.

## PR checklist (in Basecamp's extras repo)
1. Copy `send-invoice.png` into the repo's icon folder (`icons/` per the
   instructions — confirm against the path other entries actually use).
2. Add the block from `integrations-entry.yml` to `integrations.yml`, then:
   - Set `category:` to the matching number from the list at the top of that file
     (Accounting / Invoicing is the best fit — the example's `1` is a placeholder).
   - Replace `url:` with a public page that describes the Basecamp integration and
     how to set it up (a required part of the submission — see below).
   - Confirm the `image:` path matches where you placed the icon.
3. Open the pull request.

## Website requirement
The `url` must point to a page that references and explains the Basecamp
integration setup (Notifications → Connect Basecamp → pick a project). Publish a
short "Send Invoice + Basecamp" page on your marketing site and link it here.
