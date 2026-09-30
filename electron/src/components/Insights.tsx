import React from "react";

export interface InsightsData {
  localAudioSeconds: number;
  cloudAudioSeconds: number;
  minutesSaved: number;
  moneySaved: number;
  savingsWorthShowing: boolean;
  readableTimeSaved: string;
  readableMoneySaved: string;
  typingWordsPerMinute: number;
  referenceCostPerMinute: number;
  totalWords: number;
  totalDictations: number;
  totalSpeakingSeconds: number;
  correctionsApplied: number;
  wordsPerMinute: number | null;
  appsUsed: number;
  wordsByApp: { name: string; words: number }[];
  dictationsByDay: Record<string, number>;
  currentStreak: number;
  longestStreak: number;
  firstRecorded: string | null;
}

function Card({
  children,
  wide,
}: {
  children: React.ReactNode;
  wide?: boolean;
}) {
  return <section className={`stat${wide ? " stat--wide" : ""}`}>{children}</section>;
}

/**
 * The assumptions behind a figure, on the figure itself.
 *
 * Money and time saved are the two numbers on this page that could be made to
 * say anything, so the rate and the typing speed they rest on are one hover
 * away rather than buried in a footnote nobody reads.
 */
function Note({ text }: { text: string }) {
  return (
    <span className="info-dot no-drag" tabIndex={0} role="note" aria-label={text}>
      <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="12" cy="12" r="9" />
        <path d="M12 11v5.2M12 7.7v.3" />
      </svg>
      <span className="info-bubble" role="tooltip">{text}</span>
    </span>
  );
}

function plural(count: number, one: string, many: string) {
  return count === 1 ? one : many;
}

/**
 * Speaking pace as a dial.
 *
 * It fills against 160 wpm, which is roughly conversational speech — the point
 * of the arc is to place a number that means nothing on its own, not to rank
 * anyone against other people, which this app has no way of knowing.
 */
function Gauge({ value }: { value: number }) {
  const ceiling = 160;
  const fraction = Math.max(0, Math.min(1, value / ceiling));
  const radius = 62;
  const length = Math.PI * radius;

  return (
    <div className="gauge">
      <svg viewBox="0 0 160 86" role="img" aria-label={`${value} words per minute`}>
        <path
          d="M 18 78 A 62 62 0 0 1 142 78"
          fill="none"
          stroke="var(--rule-strong)"
          strokeWidth="13"
          strokeLinecap="round"
        />
        <path
          d="M 18 78 A 62 62 0 0 1 142 78"
          fill="none"
          stroke="var(--accent)"
          strokeWidth="13"
          strokeLinecap="round"
          strokeDasharray={`${length * fraction} ${length}`}
        />
      </svg>
      <div className="gauge-centre">
        <span className="gauge-label">words</span>
        <span className="gauge-value">per minute</span>
      </div>
    </div>
  );
}

/**
 * A year of days, newest column last.
 *
 * Built from a fixed 53-week window ending today rather than from the keys
 * present, so a gap reads as a gap instead of closing up.
 */
function Heatmap({ days }: { days: Record<string, number> }) {
  const today = new Date();
  const columns: { key: string; count: number; date: Date }[][] = [];
  const cursor = new Date(today);
  // Wind back to the Sunday that starts the current week.
  cursor.setDate(cursor.getDate() - cursor.getDay());

  const monthLabels: { index: number; label: string }[] = [];
  const weeks = 27;
  for (let week = weeks - 1; week >= 0; week--) {
    const column: { key: string; count: number; date: Date }[] = [];
    for (let day = 0; day < 7; day++) {
      const date = new Date(cursor);
      date.setDate(date.getDate() - week * 7 + day);
      const key = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(
        date.getDate()
      ).padStart(2, "0")}`;
      column.push({ key, count: days[key] ?? 0, date });
    }
    columns.push(column);
  }
  columns.forEach((column, index) => {
    const first = column[0].date;
    if (first.getDate() <= 7) {
      monthLabels.push({ index, label: first.toLocaleString(undefined, { month: "short" }) });
    }
  });

  const busiest = Math.max(1, ...Object.values(days));
  const level = (count: number) => {
    if (count === 0) return 0;
    const share = count / busiest;
    if (share > 0.66) return 4;
    if (share > 0.33) return 3;
    if (share > 0.12) return 2;
    return 1;
  };

  return (
    <div className="heat">
      <div className="heat-months">
        {monthLabels.map((month) => (
          <span key={`${month.label}-${month.index}`} style={{ gridColumn: month.index + 1 }}>
            {month.label}
          </span>
        ))}
      </div>
      <div className="heat-grid">
        {columns.map((column, index) => (
          <div className="heat-col" key={index}>
            {column.map((cell) => (
              <span
                key={cell.key}
                className="heat-cell"
                data-level={level(cell.count)}
                title={`${cell.key}: ${cell.count} ${plural(cell.count, "dictation", "dictations")}`}
              />
            ))}
          </div>
        ))}
      </div>
      <div className="heat-key">
        <span>Less</span>
        {[0, 1, 2, 3, 4].map((step) => (
          <span key={step} className="heat-cell" data-level={step} />
        ))}
        <span>More</span>
      </div>
    </div>
  );
}

export function Insights({ data }: { data: InsightsData | null }) {
  if (!data) {
    return <p className="empty-note">Reading your usage from ZFlow…</p>;
  }

  if (data.totalDictations === 0) {
    return (
      <>
        <p className="page-lede">Counted on this Mac. Nothing is sent anywhere.</p>
        <p className="empty-note">
          Nothing counted yet. Hold your dictation key and speak, and this page fills in.
        </p>
      </>
    );
  }

  const minutes = Math.round(data.totalSpeakingSeconds / 60);
  const topApp = data.wordsByApp[0];
  const localMinutes = Math.round(data.localAudioSeconds / 60);
  const cloudMinutes = Math.round(data.cloudAudioSeconds / 60);

  return (
    <>
      <p className="page-lede">Counted on this Mac. Nothing is sent anywhere.</p>

      <div className="stats">
        {data.savingsWorthShowing && (
          <>
            <Card>
              <p className="stat-figure">{data.readableTimeSaved}</p>
              <p className="stat-label">
                Not spent typing
                <Note text={`Your ${data.totalWords.toLocaleString()} dictated words would take about ${Math.round(data.totalWords / data.typingWordsPerMinute)} minutes to type at ${data.typingWordsPerMinute} words a minute. Saying them took ${minutes} minutes. This is the difference — nothing grander than that.`} />
              </p>
            </Card>

            <Card>
              <p className="stat-figure">{data.readableMoneySaved}</p>
              <p className="stat-label">
                Not spent on transcription
                <Note text={`${localMinutes} minutes of audio were transcribed on this Mac, at no cost. At OpenAI's published $${data.referenceCostPerMinute.toFixed(3)} a minute for speech to text, that is what those minutes would have cost.${cloudMinutes > 0 ? ` A further ${cloudMinutes} minutes went to your provider and were paid for; those are not counted here.` : ""}`} />
              </p>
            </Card>
          </>
        )}

        <Card>
          <p className="stat-figure">{data.wordsPerMinute ?? "—"}</p>
          <p className="stat-label">Words per minute</p>
          {data.wordsPerMinute ? (
            <Gauge value={data.wordsPerMinute} />
          ) : (
            <p className="stat-note">
              Needs a minute of speech in total before this means anything. You have{" "}
              {Math.round(data.totalSpeakingSeconds)}s.
            </p>
          )}
        </Card>

        <Card>
          <p className="stat-figure">{data.correctionsApplied}</p>
          <p className="stat-label">Fixes made by ZFlow</p>
          <p className="stat-note">
            Times a word from your Dictionary was put right in a finished dictation. Cleanup
            rewrites are not counted here — only the replacements ZFlow can point to.
          </p>
        </Card>

        <Card wide>
          <div className="stat-head">
            <p className="stat-title">
              {data.currentStreak} {plural(data.currentStreak, "day", "days")} in a row
            </p>
            <span className="stat-aside">
              Longest {data.longestStreak} {plural(data.longestStreak, "day", "days")}
            </span>
          </div>
          <Heatmap days={data.dictationsByDay} />
        </Card>
        <Card wide>
          <p className="stat-figure">{data.totalWords.toLocaleString()}</p>
          <p className="stat-label">Total words dictated</p>
          <div className="stat-rows">
            <p>
              <span>Dictations</span>
              {data.totalDictations.toLocaleString()}
            </p>
            <p>
              <span>Time spent speaking</span>
              {minutes >= 1 ? `${minutes} min` : `${Math.round(data.totalSpeakingSeconds)}s`}
            </p>
            {data.firstRecorded && (
              <p>
                <span>Counting since</span>
                {new Date(data.firstRecorded).toLocaleDateString()}
              </p>
            )}
          </div>
        </Card>

        <Card wide>
          <div className="stat-head">
            <p className="stat-title">Where you dictate</p>
            <span className="stat-aside">
              {data.appsUsed} {plural(data.appsUsed, "app", "apps")}
            </span>
          </div>
          <div className="bars">
            {data.wordsByApp.map((app) => {
              const share = topApp ? Math.round((app.words / topApp.words) * 100) : 0;
              return (
                <div className="bar-row" key={app.name}>
                  <span className="bar-name" title={app.name}>
                    {app.name}
                  </span>
                  <span className="bar-track">
                    <span className="bar-fill" style={{ width: `${Math.max(share, 3)}%` }} />
                  </span>
                  <span className="bar-value">{app.words.toLocaleString()}</span>
                </div>
              );
            })}
          </div>
        </Card>

      </div>

    </>
  );
}
