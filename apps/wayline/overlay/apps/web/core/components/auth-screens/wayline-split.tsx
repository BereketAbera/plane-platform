/**
 * Copyright (c) 2026 Bereket Abera
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 *
 * Wayline: the split screen for signing in and onboarding, with the chart on one side and the form on the
 * other. Layout is in packages/tailwind-config/brand/auth.css. The chart is decoration, so screen readers skip it.
 */

import type { ReactNode } from "react";
import { WAYLINE_CHART_CAPTION as CAPTION, WaylineChart } from "./wayline-chart";

type Props = {
  children: ReactNode;
  // The pane adds no padding or scrolling of its own, for content that lays itself out.
  flush?: boolean;
};

export function AuthSplit({ children, flush = false }: Props) {
  return (
    <div data-wl-auth="split" data-wl-flush={flush ? "" : undefined}>
      <div data-wl-auth="chart" aria-hidden="true">
        <WaylineChart />
        <div data-wl-auth="caption" data-shell="auth-caption">
          <span>
            {CAPTION.from} → {CAPTION.to}
          </span>
          <span data-wl-auth="caption-extra">
            {CAPTION.route} · {CAPTION.distance}
          </span>
          <span data-wl-auth="caption-extra">Not for navigation</span>
        </div>
      </div>
      <div data-wl-auth="pane">{children}</div>
    </div>
  );
}
