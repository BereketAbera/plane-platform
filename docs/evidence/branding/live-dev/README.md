# Real browser check of the branded images on plane-dev

Run on 2026-11-05 from about 00:13Z to 00:18Z, in a real browser pane (Chromium, 1440x900), against
`http://plane.dev.localhost`, after `make promote ENV=dev` published commit `4f622e3`. The images were
built from commit `1563cbf`:

| Image | Digest |
|---|---|
| web | `sha256:73a48d643f875e91673b56705a48358b8b0ce3ce831a6811fef25805735e3dfb` |
| admin | `sha256:279dfd7f06ccce84b06dbfbe7b7c756d406c81d2320e28a6b5d013c3ec64685c` |
| space | `sha256:a8c49151ee9471439bf6fba49c23814a64904d4709f92f1258092f3b5fcdd33a` |
| backend | `sha256:4add277ce63eb11d4159f266f7dc880fc5254f1e4e13dac050ab97c90460658c` |

The account was the generated smoke admin from `.local/test-accounts.env`. No other account was used.

## What was done by hand, and what was seen

| Step | Result | File |
|---|---|---|
| Open `/` after the promotion, with the browser's cache from an earlier visit | **Defect.** The cached upstream page showed, titled "Sign up - Plane". `fetch('/', {cache:'default'})` returned the old title and `Last-Modified`; `{cache:'no-store'}` returned the new one. See below | `00-stale-cache-after-promotion.jpg` |
| Open `/` after refreshing the cache entry | Wayline sign-in with the chart illustration, the credit line and the source link | `01-sign-in-dark.jpg` |
| Sign in through the form: email, then password | Reached onboarding. This was the first real browser sign-in on this deployment | `02-onboarding.jpg` |
| Finish onboarding | Home, with "Welcome to Wayline" and Wayline text in the quickstart cards | `03-home-dark.jpg` |
| Open work items, switch to the board layout | Board renders on real data | `04-board-dark.jpg` |
| Add a work item from the board's quick add | `SMOKE-8` created, and still there after a reload | `05-board-light.jpg` |
| Same board with the light scheme | Chart paper, magenta accent, ink sidebar | `05-board-light.jpg` |
| Create a page, type a title and a line of text in tab 1, with the same page open in tab 2 | Tab 2 showed both within 2 seconds | `06-page-editor.jpg` |
| Reload tab 2 | The title and text came back from the server | |
| Open `/god-mode/` and sign in as the instance admin | General settings: instance name Wayline, telemetry off | `07-admin-sign-in.jpg`, `08-admin-general.jpg` |
| Open `/spaces/` | Wayline chrome and a source link | `09-public-space.jpg` |
| Open `/licenses/` | Index of `COPYRIGHT.txt`, `LICENSE.txt`, `MODIFICATIONS.txt`, `NOTICE.txt`, and both font licences | |
| `curl -I /source` | 302 to `https://github.com/BereketAbera/plane-platform/tree/1563cbfbe89536541c041ec59f241edeab3740c2` | |

Not done here: an attachment through the file dialog, since a pane cannot drive one (the API smoke covers upload bytes),
a public board with real content, Safari, and any check on plane-prod-sim.

## The stale page

nginx in the web and admin images sends `ETag` and `Last-Modified` with no `Cache-Control`, the same as upstream's
config. A browser may then reuse the HTML without asking, for about a tenth of the file's age. The upstream file was
a week old, so the old sign-in page kept showing after the promotion, with no error. Hashed assets get no long
lifetime either, so they are revalidated for no reason. The space image is a Node server and already sets
`public, max-age=31536000, immutable` on its assets.

## Console

React errors #418 and #423 (hydration mismatch) appear on the web app. The earlier run on upstream's images in both
environments shows the same two errors, so branding did not introduce them. Their cause was not found. The app works
past them.

## Text seen

- A workspace created on the branded backend seeds "Welcome to Wayline". A workspace created before the promotion
  keeps "Welcome to Plane", because seed text is written once.
- The sidebar has a raw label, `aria_labels.app_sidebar.close_workspace_menu`, in its accessibility tree. It is not
  visible on screen.
