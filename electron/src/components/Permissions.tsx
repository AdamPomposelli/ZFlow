import React from "react";
import { Icon } from "../icons";

type State = "granted" | "missing" | "not_needed";

interface Item {
  access: string;
  title: string;
  purpose: string;
  state: State;
}

interface Report {
  items: Item[];
  allGranted: boolean;
  outstanding: number;
}

const GLYPH: Record<string, string> = {
  microphone: "mic",
  accessibility: "wand",
  screen_recording: "camera",
};

function Check() {
  return (
    <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
      <path d="m5 12.5 4.6 4.6L19 7" />
    </svg>
  );
}

/**
 * What macOS has to let ZFlow do, and a way to say yes to each.
 *
 * The asking is the app's job, not this window's: a permission dialog is
 * attributed to the process that raises it, and a dialog raised here would
 * name the settings window instead of the app that needs the access. So this
 * only reports and requests over the bridge.
 */
export function Permissions() {
  const [report, setReport] = React.useState<Report | null>(null);
  const [asking, setAsking] = React.useState<string | null>(null);

  const refresh = React.useCallback(async () => {
    const next = (await window.zflow?.permissions()) as Report | undefined;
    if (next) setReport(next);
  }, []);

  React.useEffect(() => {
    void refresh();
    // Granting happens in System Settings, in another window: the answer
    // arrives while this page is just sitting there, so it has to keep
    // looking. Slower once there is nothing outstanding — a permission can
    // still be taken away, but not by anything happening here.
    const period = report?.allGranted ? 6000 : 1500;
    const timer = window.setInterval(() => void refresh(), period);
    const onFocus = () => void refresh();
    window.addEventListener("focus", onFocus);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", onFocus);
    };
  }, [refresh, report?.allGranted]);

  if (!report) return null;

  const ask = async (access: string) => {
    setAsking(access);
    try {
      await window.zflow?.permissionRequest(access);
    } catch {
      // The app is gone or would not answer. Nothing useful to say here that
      // the row does not already say, and the button has to come back.
      setAsking(null);
      return;
    }
    // The dialog or the Settings pane is now up; the poll above picks up the
    // answer whenever it comes.
    window.setTimeout(() => setAsking(null), 2500);
    void refresh();
  };

  return (
    <>
      {report.items.map((item) => {
        const Glyph = Icon[GLYPH[item.access] ?? "shield"];
        return (
          <div
            key={item.access}
            className={`row row--permission row--permission-${item.state}`}
          >
            <div className="row-text">
              <p className="row-title">
                {Glyph && (
                  <span className="row-glyph" aria-hidden="true">
                    <Glyph />
                  </span>
                )}
                {item.title}
              </p>
              <p className="row-desc">{item.purpose}</p>
            </div>
            <div className="row-control">
              {item.state === "granted" && (
                <span className="grant grant--done">
                  <span className="grant-tick" aria-hidden="true">
                    <Check />
                  </span>
                  Granted
                </span>
              )}
              {item.state === "missing" && (
                <button
                  className="btn btn--primary no-drag"
                  onClick={() => void ask(item.access)}
                  disabled={asking === item.access}
                >
                  {asking === item.access ? "Waiting…" : "Grant"}
                </button>
              )}
              {item.state === "not_needed" && (
                <span className="grant grant--idle">Not needed</span>
              )}
            </div>
          </div>
        );
      })}
    </>
  );
}
