/**
 * Copyright (c) 2026 Bereket Abera
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 *
 * Wayline: the chart side of the split-screen admin sign-in, and the source offer under the form.
 * The chart is the same generated sheet as the main app's sign-in. Its wl-c-* marks and their
 * [data-wl-auth="chart"] tokens are in packages/tailwind-config/brand/auth.css. Layout is in brand/admin.css.
 */

import { PlaneLockup } from "@plane/propel/icons";
import { WaylineChart } from "./wayline-chart";

export function AuthAside() {
  return (
    <aside data-wl-auth="chart" data-wl-admin-aside>
      <WaylineChart />
      <div data-wl-admin-legend>
        <PlaneLockup height={24} width={115} className="text-primary" />
        <p className="text-h5-medium text-primary">Chart the course for this instance.</p>
        <p className="text-body-sm-regular text-secondary">
          Workspaces, authentication, email and AI settings for everyone on this deployment.
        </p>
      </div>
    </aside>
  );
}

// A plain anchor: /source sits outside this app's /god-mode/ basename, so a router link would miss it.
export function AuthCredit() {
  return (
    <footer data-wl-admin-credit className="w-full flex-shrink-0 py-4 text-center text-11 text-secondary">
      Built on Plane Community Edition{" · "}
      <a href="/source" target="_blank" rel="noopener noreferrer">
        Source code
      </a>
    </footer>
  );
}
