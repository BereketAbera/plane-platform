/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 *
 * Modified for Wayline: the artwork is replaced. The export name stays so render sites need no edits.
 */

import * as React from "react";

import type { ISvgIcons } from "../type";

export function PlaneLogo({ width = "32", height = "32", className, color = "currentColor" }: ISvgIcons) {
  return (
    <svg
      width={width}
      height={height}
      viewBox="0 0 32 32"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={className}
    >
      <path d="M11 25.5H15.5L22.2 12.4" fill="none" stroke="var(--wl-logo-route, currentColor)" strokeWidth="3" />
      <circle cx="6.5" cy="25.5" r="3.75" fill="none" stroke={color} strokeWidth="3" />
      <path d="M24.5 2L31 8.5L24.5 15L18 8.5Z" fill={color} />
    </svg>
  );
}
