import React from "react";

const s = {
  width: 17,
  height: 17,
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.7,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

export const Icon: Record<string, () => JSX.Element> = {
  sliders: () => (
    <svg {...s}><line x1="4" y1="7" x2="20" y2="7" /><circle cx="9" cy="7" r="2.2" /><line x1="4" y1="17" x2="20" y2="17" /><circle cx="15" cy="17" r="2.2" /></svg>
  ),
  cpu: () => (
    <svg {...s}><rect x="6" y="6" width="12" height="12" rx="2" /><rect x="9.5" y="9.5" width="5" height="5" rx="1" /><path d="M9 3v3M15 3v3M9 18v3M15 18v3M3 9h3M3 15h3M18 9h3M18 15h3" /></svg>
  ),
  sparkles: () => (
    <svg {...s}><path d="M12 3l1.6 4.4L18 9l-4.4 1.6L12 15l-1.6-4.4L6 9l4.4-1.6z" /><path d="M18.5 15.5l.7 1.9 1.9.7-1.9.7-.7 1.9-.7-1.9-1.9-.7 1.9-.7z" /></svg>
  ),
  beaker: () => (
    <svg {...s}><path d="M9 3v6.2L4.6 17A2 2 0 0 0 6.3 20h11.4a2 2 0 0 0 1.7-3L15 9.2V3" /><path d="M8 3h8M7.5 14h9" /></svg>
  ),
  shield: () => (
    <svg {...s}><path d="M12 3l7 3v5.5c0 4.3-2.9 8.2-7 9.5-4.1-1.3-7-5.2-7-9.5V6z" /><path d="m9.2 12 2 2 3.6-3.8" /></svg>
  ),
  clock: () => (
    <svg {...s}><circle cx="12" cy="12" r="8.5" /><path d="M12 7.5V12l3 1.8" /></svg>
  ),
  book: () => (
    <svg {...s}><path d="M5 4.5h9a3 3 0 0 1 3 3V20a2.5 2.5 0 0 0-2.5-2.5H5z" /><path d="M5 4.5V20" /></svg>
  ),
  cloud: () => (
    <svg {...s} width={15} height={15}><path d="M7 18h10a3.5 3.5 0 0 0 .3-7 5 5 0 0 0-9.6-1.3A3.8 3.8 0 0 0 7 18z" /><path d="m10.5 13.5 1.5 1.5 3-3" /></svg>
  ),
  // Row glyphs: each one says what the setting touches, so a page can be
  // scanned rather than read.
  wand: () => (
    <svg {...s}><path d="M4 20 15 9" /><path d="m14.5 5.5 4 4" /><path d="M16.5 3.5 20.5 7.5" /><path d="M7 4v3M5.5 5.5h3M18 15v3M16.5 16.5h3" /></svg>
  ),
  window: () => (
    <svg {...s}><rect x="3.5" y="5" width="17" height="14" rx="2.2" /><path d="M3.5 9.5h17" /><circle cx="6.6" cy="7.2" r=".7" fill="currentColor" stroke="none" /><circle cx="9" cy="7.2" r=".7" fill="currentColor" stroke="none" /></svg>
  ),
  camera: () => (
    <svg {...s}><path d="M3.5 8.5h3.2l1.4-2h5.8l1.4 2h3.2a1.5 1.5 0 0 1 1.5 1.5v7a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 2 17v-7A1.5 1.5 0 0 1 3.5 8.5z" /><circle cx="11" cy="13.2" r="3.2" /></svg>
  ),
  fileText: () => (
    <svg {...s}><path d="M6 3.5h7L18.5 9v11.5H6z" /><path d="M13 3.5V9h5.5" /><path d="M8.7 13h7M8.7 16.3h4.6" /></svg>
  ),
  graduate: () => (
    <svg {...s}><path d="m12 4 9 4.2-9 4.2-9-4.2z" /><path d="M6.6 10.4V15c0 1.4 2.4 2.6 5.4 2.6s5.4-1.2 5.4-2.6v-4.6" /><path d="M20.4 8.8v5" /></svg>
  ),
  scale: () => (
    <svg {...s}><path d="M12 4.5v15M6.5 19.5h11" /><path d="M4 9.5h16" /><path d="M4 9.5 1.8 14.4a2.6 2.6 0 0 0 4.4 0z" /><path d="M20 9.5 17.8 14.4a2.6 2.6 0 0 0 4.4 0z" /></svg>
  ),
  quote: () => (
    <svg {...s}><path d="M9.2 6.5C6.6 7.6 5 9.9 5 12.7v4.8h5.2v-5.2H7.6c0-1.9.7-3.3 2.4-4.1z" /><path d="M19 6.5c-2.6 1.1-4.2 3.4-4.2 6.2v4.8H20v-5.2h-2.6c0-1.9.7-3.3 2.4-4.1z" /></svg>
  ),
  bolt: () => (
    <svg {...s}><path d="M13.2 2.5 5 13.4h5.4L9.8 21.5 18.5 10h-5.6z" /></svg>
  ),
  gauge: () => (
    <svg {...s}><path d="M4 17a8.5 8.5 0 1 1 16 0" /><path d="m12 14.5 3.8-4.4" /><circle cx="12" cy="16.2" r="1.4" /></svg>
  ),
  gem: () => (
    <svg {...s}><path d="M7 3.5h10l4 5.2-9 11.8L3 8.7z" /><path d="M3 8.7h18M7 3.5l1.6 5.2L12 20.5l3.4-11.8L17 3.5" /></svg>
  ),
  dock: () => (
    <svg {...s}><rect x="2.8" y="14.5" width="18.4" height="6" rx="2" /><rect x="6" y="16.6" width="2.6" height="2.6" rx=".7" /><rect x="10.7" y="16.6" width="2.6" height="2.6" rx=".7" /><rect x="15.4" y="16.6" width="2.6" height="2.6" rx=".7" /><path d="M12 3.5v7.5m0 0 3-3m-3 3-3-3" /></svg>
  ),
  globe: () => (
    <svg {...s}><circle cx="12" cy="12" r="8.5" /><path d="M3.5 12h17" /><path d="M12 3.5c2.3 2.4 3.4 5.3 3.4 8.5S14.3 18.1 12 20.5c-2.3-2.4-3.4-5.3-3.4-8.5S9.7 5.9 12 3.5z" /></svg>
  ),
  translate: () => (
    <svg {...s}><path d="M3.5 6.2h8" /><path d="M7.5 4.2v2" /><path d="M9.6 6.2c0 3.5-2.4 6.6-6.1 7.8" /><path d="M5.2 9.6c1 2 2.8 3.4 5.1 4.1" /><path d="m12.8 20 3.8-9.4L20.4 20" /><path d="M14.1 16.9h5" /></svg>
  ),
  volume: () => (
    <svg {...s}><path d="M5 9.5h3.2L12.5 6v12L8.2 14.5H5z" /><path d="M15.8 9.4a3.7 3.7 0 0 1 0 5.2" /><path d="M18.3 7a7.2 7.2 0 0 1 0 10" /></svg>
  ),
  mute: () => (
    <svg {...s}><path d="M5 9.5h3.2L12.5 6v12L8.2 14.5H5z" /><path d="m16 9.8 4.4 4.4M20.4 9.8 16 14.2" /></svg>
  ),
  login: () => (
    <svg {...s}><path d="M13.5 3.5h4a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2h-4" /><path d="M10 16.2 14 12l-4-4.2" /><path d="M14 12H3.8" /></svg>
  ),
  menubar: () => (
    <svg {...s}><rect x="2.8" y="4" width="18.4" height="16" rx="2.2" /><path d="M2.8 8.4h18.4" /><path d="M15 6.2h3.4" /></svg>
  ),
  mic: () => (
    <svg {...s}><rect x="9.2" y="3" width="5.6" height="10.4" rx="2.8" /><path d="M5.6 11.4a6.4 6.4 0 0 0 12.8 0" /><path d="M12 17.8V21" /></svg>
  ),
  search: () => (
    <svg {...s}><circle cx="11" cy="11" r="6.6" /><path d="m16 16 4.5 4.5" /></svg>
  ),
  close: () => (
    <svg {...s}><path d="m6 6 12 12M18 6 6 18" /></svg>
  ),
  chevron: () => (
    <svg {...s}><path d="m9 6 6 6-6 6" /></svg>
  ),
  download: () => (
    <svg {...s}><path d="M12 3.5v11m0 0 4-4m-4 4-4-4" /><path d="M4 16.5v2.2a1.8 1.8 0 0 0 1.8 1.8h12.4a1.8 1.8 0 0 0 1.8-1.8v-2.2" /></svg>
  ),
  clipboard: () => (
    <svg {...s}><rect x="5.5" y="4.6" width="13" height="15.4" rx="2" /><rect x="9" y="2.6" width="6" height="3.6" rx="1.2" /></svg>
  ),
  pencil: () => (
    <svg {...s}><path d="M4 20h4L19.2 8.8a2 2 0 0 0 0-2.8l-1.2-1.2a2 2 0 0 0-2.8 0L4 16z" /><path d="m14.5 6.5 3 3" /></svg>
  ),
  enter: () => (
    <svg {...s}><path d="M20 5v6.5a2 2 0 0 1-2 2H4.6" /><path d="m8.6 9.5-4 4 4 4" /></svg>
  ),
  chart: () => (
    <svg {...s}><path d="M4 20.2V3.8" /><path d="M4 20.2h16" /><rect x="7.2" y="12" width="3" height="5" rx="1" /><rect x="12.3" y="8.2" width="3" height="8.8" rx="1" /><rect x="17.4" y="10.2" width="3" height="6.8" rx="1" /></svg>
  ),
  upload: () => (
    <svg {...s}><path d="M12 16.5v-13m0 0-4 4m4-4 4 4" /><path d="M4 16.5v2.2a1.8 1.8 0 0 0 1.8 1.8h12.4a1.8 1.8 0 0 0 1.8-1.8v-2.2" /></svg>
  ),
  notes: () => (
    <svg {...s}><path d="M6 3.5h8.5L19 8v12.5H6z" /><path d="M14.5 3.5V8H19" /><path d="M9 12.2h6M9 15.6h4" /><circle cx="18.6" cy="17.4" r="3.1" fill="none" /><path d="M18.6 15.9v1.5l1 .7" /></svg>
  ),
};
