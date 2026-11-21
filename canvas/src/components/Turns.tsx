// The agent's open turns: what it was asked, the changes it made for it, and your accept or reject of the whole.

import { useCallback, useEffect, useRef, useState } from 'react'

import { acceptTurn, changes, rejectTurn, turns as fetchTurns, type TurnItem } from '../api'

export function Turns({ schema, onError }: { schema: string; onError: (message: string) => void }) {
  const [items, setItems] = useState<TurnItem[]>([])
  const [open, setOpen] = useState<number | null>(null)
  const [rejecting, setRejecting] = useState<number | null>(null)
  // Only the schema shown now: an answer for the one before, arriving late, is dropped.
  const shown = useRef(schema)
  shown.current = schema
  const load = useCallback(() => {
    const asked = schema
    fetchTurns(asked).then((t) => { if (shown.current === asked) setItems(t) }, () => { if (shown.current === asked) setItems([]) })
  }, [schema])
  useEffect(() => {
    setItems([])
    setRejecting(null)
    load()
    return changes((c) => { if (c.schema === schema && /change|undo|turn/.test(c.kind)) load() })
  }, [schema, load])
  const pending = items.filter((i) => i.turn.status === 'open' && i.changes.length > 0)
  if (!pending.length) return null
  const act = (p: Promise<unknown>) => p.then(load, (e) => onError(String(e.message ?? e)))
  return (
    <div className="sf-turns" aria-label="The agent's turns to review">
      {pending.map(({ turn, changes: done }) => (
        <div key={turn.id} className="sf-turn">
          <button type="button" className="sf-turn-head" onClick={() => setOpen(open === turn.id ? null : turn.id)} aria-expanded={open === turn.id}>
            <span className="sf-caption">turn {turn.id} · {turn.by}</span>
            <span className="sf-strong">{turn.summary}</span>
            <span className="sf-muted sf-small">{done.length} {done.length === 1 ? 'change' : 'changes'} {open === turn.id ? '▾' : '▸'}</span>
          </button>
          <span className="sf-row-gap">
            <button type="button" className="sf-chip sf-on" onClick={() => act(acceptTurn(schema, turn.id))}>Accept</button>
            {rejecting === turn.id ? (
              <>
                <span className="sf-small">Take back all {done.length} {done.length === 1 ? 'change' : 'changes'}?</span>
                <button type="button" className="sf-chip sf-danger-chip" onClick={() => { setRejecting(null); act(rejectTurn(schema, turn.id)) }}>Yes, reject the turn</button>
                <button type="button" className="sf-chip" onClick={() => setRejecting(null)}>Keep it</button>
              </>
            ) : (
              <button type="button" className="sf-chip sf-danger-chip" onClick={() => setRejecting(turn.id)}>Reject</button>
            )}
          </span>
          {open === turn.id && (
            <ol className="sf-turn-list">
              {done.map((c) => <li key={c.sequence}><span className="sf-muted sf-small">#{c.sequence}</span> {(c.summaries ?? []).join('; ')}</li>)}
            </ol>
          )}
        </div>
      ))}
    </div>
  )
}
