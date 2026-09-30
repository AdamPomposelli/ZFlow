import React from "react";
import { Icon } from "../icons";
import { PIPELINE_PRESETS, type PipelinePreset } from "../settings-schema";

export interface PipelineState {
  cleanup: boolean;
  context: boolean;
  screenshot: boolean;
}

/**
 * The preset that matches the stage toggles right now, or null.
 *
 * Mirrors `PipelineMode.matching` in the app: the mode is *derived* from the
 * toggles rather than stored beside them, so the card and the switches below
 * it cannot drift apart. A combination no preset covers is not an error — it
 * is Custom.
 */
export function matchingPreset(state: PipelineState): PipelinePreset | null {
  return (
    PIPELINE_PRESETS.find(
      (preset) =>
        preset.cleanup === state.cleanup &&
        preset.context === state.context &&
        preset.screenshot === state.screenshot
    ) ?? null
  );
}

export function ModeSelector({
  state,
  onPick,
}: {
  state: PipelineState;
  onPick: (preset: PipelinePreset) => void;
}) {
  const current = matchingPreset(state);

  return (
    <div className="modes">
      {PIPELINE_PRESETS.map((preset) => {
        const Glyph = Icon[preset.icon] ?? Icon.gauge;
        const selected = current?.id === preset.id;
        return (
          <button
            key={preset.id}
            className="mode-card no-drag"
            aria-pressed={selected}
            data-selected={selected}
            onClick={() => onPick(preset)}
          >
            <span className="mode-glyph">
              <Glyph />
            </span>
            <span className="mode-title">
              {preset.title}
              <span className="mode-wait">— {preset.wait}</span>
            </span>
            <span className="mode-summary">{preset.summary}</span>
          </button>
        );
      })}

      {/* Only there when it applies. An always-present Custom card would be a
          fourth thing to choose; this way it simply reports where you are. */}
      {!current && (
        <div className="mode-card mode-card--custom" data-selected="true" aria-current="true">
          <span className="mode-glyph">
            <Icon.sliders />
          </span>
          <span className="mode-title">
            Custom
            <span className="mode-tag">In use</span>
          </span>
          <span className="mode-summary">
            Your own combination of the stages below. Pick a preset to go back to one of the three.
          </span>
        </div>
      )}
    </div>
  );
}
