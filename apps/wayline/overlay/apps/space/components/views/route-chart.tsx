/**
 * Copyright (c) 2026 Bereket Abera
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 *
 * Wayline: the decorative side of the split-screen sign-in. The same generated sheet as the main app's sign-in.
 */

import { WAYLINE_CHART_CAPTION as CAPTION, WaylineChart } from "./wayline-chart";

export function RouteChart() {
  return (
    <div data-wl-auth="chart" data-wl-space="auth-art" aria-hidden="true">
      <WaylineChart />
      <div data-wl-auth="caption" data-shell="auth-caption">
        <span>
          {CAPTION.from} → {CAPTION.to}
        </span>
        <span data-wl-auth="caption-extra">Not for navigation</span>
      </div>
    </div>
  );
}
