# Real browser check on the final images, after a full restore

Run on 2026-11-05 from about 08:36Z to 08:39Z, in a real browser pane (Chromium), through Traefik, by hand from the
coordinating session. Both environments ran the images built from `84b63d9`: web `3d7575a1`, admin `ce7adc37`,
space `5f0119ff`, backend `8c04bd18`. The cluster was new: `make drill-clean-restore` had deleted the old one and
restored both environments from backup, and then `make down` and `make up` had stopped and resumed it. `make test` was
running at the same time, so this was not a quiet machine.

The accounts were the generated smoke admins from `.local/test-accounts.env`, which the restore put back.

| Step | Result | File |
|---|---|---|
| `plane.dev.localhost`, light scheme | Sign-in page with the chart illustration, the credit line and the source link. The earlier session cookie no longer worked after the restore, so this was a new sign-in | `01-sign-in-light-dev.jpg` |
| Sign in through the form on dev | Reached the workspace home | |
| Open work items, board layout | `SMOKE-8`, typed by hand into the board at about 00:17Z before the delete, is still there | `02-board-after-restore-dev.jpg` |
| Publish the project with a `POST` from the signed-in page, not through the UI's button, then open `/spaces/issues/<anchor>/` | The published board renders with Wayline's chrome, the `SMOKE-8` row and the source link | `03-published-board-dev.jpg` |
| Unpublish with `DELETE` | 204, and the public settings route then answers 404 | |
| `plane.prod-sim.localhost`, sign in through the form | First real browser sign-in on prod-sim. Reached onboarding, then the workspace home | `04-onboarding-prod-sim.jpg` |
| Both sessions at once, read at 08:38:18Z | `GET /api/users/me/` answers 200 in each tab, so signing in on prod-sim did not end dev's session | |
| `plane.prod-sim.localhost/god-mode/` | Wayline's instance admin sign-in page and the source link. Not signed in here | |

## What this does not show

- Safari and Firefox.
- The publish button in the UI: its menu did not open from a scripted click, so the board was published by API from the page.
- An anonymous view of the published board. The tab carried the dev session cookie, so the page shows `smoke-admin` at
  the top. The API smoke test reads the same board anonymously.
- An admin sign-in on prod-sim.

## Seen

- On a narrow window, the fixed credit badge on the published board covers part of the row beneath it until the list
  scrolls. Cosmetic.
- React errors #418 and #423 on the public page's console, the same two errors as on upstream's images. Cause not found.
- `SMOKE-1` in this workspace reads "Welcome to Plane", because it was seeded before the branded backend. New workspaces
  seed "Welcome to Wayline".
