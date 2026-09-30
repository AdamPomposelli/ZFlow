import React from "react";

export interface Entry {
  id: string;
  original: string;
  corrected: string;
  occurrences: number;
}

export interface Group {
  corrected: string;
  variants: Entry[];
}

export function groupEntries(entries: Entry[]): Group[] {
  const order: string[] = [];
  const buckets = new Map<string, Entry[]>();
  for (const entry of entries) {
    const key = entry.corrected.toLowerCase();
    if (!buckets.has(key)) {
      buckets.set(key, []);
      order.push(key);
    }
    buckets.get(key)!.push(entry);
  }
  return order.map((key) => ({
    corrected: buckets.get(key)![0].corrected,
    variants: buckets.get(key)!,
  }));
}

function Check() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round">
      <path d="m5 13 4.5 4.5L19 7" />
    </svg>
  );
}

/**
 * One correct spelling with every misheard form that maps onto it.
 *
 * The heard forms are tags: type, press Enter, another tag. The correct
 * spelling is editable in place, and a confirm appears only once something has
 * actually changed — so nothing is written by accident, and nothing needs a
 * Save button sitting there permanently.
 */
function GroupCard({
  group,
  onAddVariant,
  onRemoveVariant,
  onRename,
  onRemoveGroup,
}: {
  group: Group;
  onAddVariant: (corrected: string, heard: string) => void;
  onRemoveVariant: (id: string) => void;
  onRename: (from: string, to: string) => void;
  onRemoveGroup: (corrected: string) => void;
}) {
  const [draft, setDraft] = React.useState(group.corrected);
  const [tag, setTag] = React.useState("");
  React.useEffect(() => setDraft(group.corrected), [group.corrected]);

  const dirty = draft.trim() !== group.corrected && draft.trim().length > 0;

  const commitTag = () => {
    const value = tag.trim();
    if (!value) return;
    onAddVariant(group.corrected, value);
    setTag("");
  };

  return (
    <div className="dict-group">
      <div className="dict-tags">
        {group.variants.map((variant) => (
          <span className="tag" key={variant.id}>
            {variant.original}
            {variant.occurrences > 1 && <em>×{variant.occurrences}</em>}
            <button
              onClick={() => onRemoveVariant(variant.id)}
              aria-label={`Remove ${variant.original}`}
            >
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round">
                <path d="M6 6l12 12M18 6L6 18" />
              </svg>
            </button>
          </span>
        ))}
        <input
          className="tag-input"
          value={tag}
          placeholder={group.variants.length ? "Add a misspelling" : "What the transcriber writes"}
          aria-label={`Add a misspelling for ${group.corrected}`}
          onChange={(event) => setTag(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === ",") {
              event.preventDefault();
              commitTag();
            }
            if (event.key === "Backspace" && !tag && group.variants.length) {
              onRemoveVariant(group.variants[group.variants.length - 1].id);
            }
          }}
          onBlur={commitTag}
        />
      </div>

      <div className="dict-arrow">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
          <path d="M12 5v13M7 13l5 5 5-5" />
        </svg>
        <span>becomes</span>
      </div>

      <div className="dict-output">
        <input
          className="dict-output-field"
          value={draft}
          aria-label="Correct spelling"
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && dirty) onRename(group.corrected, draft.trim());
            if (event.key === "Escape") setDraft(group.corrected);
          }}
        />
        {dirty && (
          <button
            className="confirm-chip confirm-chip--inline"
            onClick={() => onRename(group.corrected, draft.trim())}
            aria-label="Confirm the new spelling"
          >
            <Check />
          </button>
        )}
        <button
          className="dict-remove"
          onClick={() => onRemoveGroup(group.corrected)}
          aria-label={`Forget ${group.corrected}`}
        >
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
            <path d="M4 7h16M9 7V5h6v2M7 7l1 13h8l1-13" />
          </svg>
        </button>
      </div>
    </div>
  );
}

/**
 * A word being added, before it exists.
 *
 * It is deliberately the same shape as a saved card: several misspellings as
 * tags, one correct spelling, the same arrow between them. An add form that
 * behaved differently from the thing it creates — one text box where the real
 * card takes many — was the confusing part.
 *
 * The confirm button is always there and simply disabled until both halves are
 * filled, because a button that appears only once you have guessed the rule
 * cannot teach you the rule.
 */
function DraftCard({
  onSave,
  onCancel,
}: {
  onSave: (corrected: string, heard: string[]) => void;
  onCancel: () => void;
}) {
  const [heard, setHeard] = React.useState<string[]>([]);
  const [tag, setTag] = React.useState("");
  const [corrected, setCorrected] = React.useState("");
  const tagRef = React.useRef<HTMLInputElement>(null);

  React.useEffect(() => tagRef.current?.focus(), []);

  const addTag = () => {
    const value = tag.trim();
    if (!value) return;
    setHeard((prev) => (prev.some((x) => x.toLowerCase() === value.toLowerCase()) ? prev : [...prev, value]));
    setTag("");
  };

  // Whatever is still sitting in the tag box counts: nobody should lose a word
  // for not having pressed Enter.
  const pending = tag.trim();
  const all = pending && !heard.some((x) => x.toLowerCase() === pending.toLowerCase())
    ? [...heard, pending]
    : heard;
  const ready = all.length > 0 && corrected.trim().length > 0;

  const save = () => {
    if (!ready) return;
    onSave(corrected.trim(), all);
  };

  return (
    <div className="dict-group dict-group--draft">
      <div className="dict-tags">
        {heard.map((word) => (
          <span className="tag" key={word}>
            {word}
            <button
              onClick={() => setHeard((prev) => prev.filter((x) => x !== word))}
              aria-label={`Remove ${word}`}
            >
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round">
                <path d="M6 6l12 12M18 6L6 18" />
              </svg>
            </button>
          </span>
        ))}
        <input
          ref={tagRef}
          className="tag-input"
          value={tag}
          placeholder={heard.length ? "Add another misspelling" : "What the transcriber writes"}
          aria-label="Misspelling to add"
          onChange={(event) => setTag(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === ",") {
              event.preventDefault();
              addTag();
            }
            if (event.key === "Backspace" && !tag && heard.length) {
              setHeard((prev) => prev.slice(0, -1));
            }
            if (event.key === "Escape") onCancel();
          }}
        />
      </div>

      <div className="dict-arrow">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
          <path d="M12 5v13M7 13l5 5 5-5" />
        </svg>
        <span>becomes</span>
      </div>

      <div className="dict-output">
        <input
          className="dict-output-field"
          value={corrected}
          placeholder="The right spelling"
          aria-label="Correct spelling to add"
          onChange={(event) => setCorrected(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") save();
            if (event.key === "Escape") onCancel();
          }}
        />
        <button
          className="btn btn--primary"
          onClick={save}
          disabled={!ready}
          title={ready ? undefined : "Fill in both sides first"}
        >
          Add
        </button>
        <button className="dict-remove" onClick={onCancel} aria-label="Cancel">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
            <path d="M6 6l12 12M18 6L6 18" />
          </svg>
        </button>
      </div>
    </div>
  );
}

export function Dictionary({
  entries,
  onAddVariant,
  onRemoveVariant,
  onRename,
  onRemoveGroup,
}: {
  entries: Entry[];
  onAddVariant: (corrected: string, heard: string) => void;
  onRemoveVariant: (id: string) => void;
  onRename: (from: string, to: string) => void;
  onRemoveGroup: (corrected: string) => void;
}) {
  const groups = groupEntries(entries);
  const [adding, setAdding] = React.useState(false);

  return (
    <>
      <p className="page-lede">
        What the transcriber gets wrong, and what it should have written. Every misspelling on
        the left is rewritten to the word on the right in each later dictation — outright, so it
        works even with cleanup switched off. Correct a word just after a dictation and it lands
        here on its own. For a word that has no particular wrong spelling, and that you only want
        the cleanup model to know about, use Custom vocabulary in Post-Processing.
      </p>

      {groups.map((group) => (
        <GroupCard
          key={group.corrected}
          group={group}
          onAddVariant={onAddVariant}
          onRemoveVariant={onRemoveVariant}
          onRename={onRename}
          onRemoveGroup={onRemoveGroup}
        />
      ))}

      {adding ? (
        <DraftCard
          onSave={(corrected, heard) => {
            for (const word of heard) onAddVariant(corrected, word);
            setAdding(false);
          }}
          onCancel={() => setAdding(false)}
        />
      ) : (
        /* A dashed outline says "this makes a new one" the way a filled card
           cannot: the previous version was a half-real card sitting at the
           bottom, and people read it as a row that had failed to save. */
        <button className="dict-add no-drag" onClick={() => setAdding(true)}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round">
            <path d="M12 5v14M5 12h14" />
          </svg>
          Add a word
        </button>
      )}
    </>
  );
}
