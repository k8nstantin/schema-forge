// Review: the rules the agent proposed. The system has verified each (written right, a repeat or not, what it
// contradicts, what it would break); you choose hard or soft, and approve or reject. Nothing holds until approved.

import { useEffect, useState } from 'react'

import { approve, linkRule, proposalEnforce, proposals as fetchProposals, reject } from '../api'
import type { Proposal, Verdict } from '../model'
import { useWorkbench } from '../state'
import { EnforceToggle, Findings, TallyBar } from './parts'
import { scopeTitle } from './scope'

type Item = { proposal: Proposal; verdict: Verdict | null }

const MARK: Record<string, [string, string]> = {
  ok: ['✓', 'sf-mark-ok'],
  new: ['+', 'sf-mark-new'],
  reuse: ['↺', 'sf-mark-reuse'],
  warn: ['!', 'sf-mark-warn'],
  bad: ['✕', 'sf-mark-bad'],
}
const STATE: Record<string, string> = { ready: 'Verified', conflict: 'Conflict', duplicate: 'Repeats a rule', invalid: 'Cannot be taken' }

export function ReviewView() {
  const { name, rules, reloadRules } = useWorkbench()
  const [items, setItems] = useState<Item[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const load = () => fetchProposals(name).then(setItems, (e) => setError(String(e.message ?? e)))
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { load() }, [name, rules])
  if (!items) return <div className="sf-page sf-muted">{error ?? 'Reading the proposals…'}</div>
  const open = items.filter((i) => i.proposal.status === 'proposed')
  const done = items.filter((i) => i.proposal.status !== 'proposed').reverse()
  const ready = open.filter((i) => i.verdict?.state === 'ready')
  const act = (p: Promise<unknown>) => p.then(() => { setError(null); reloadRules(); load() }, (e) => setError(String(e.message ?? e)))
  return (
    <div className="sf-page sf-review">
      <div className="sf-flow">
        {[
          ['1 · the agent', 'Proposes', 'rules, each with its evidence'],
          ['2 · the system', 'Verifies', 'written right, repeats, contradictions, what it would break'],
          ['3 · you', 'Approve', 'hard or soft, or reject'],
          ['4 · the system', 'Enforces', 'through the MCP, on every change'],
        ].map(([n, t, s], i) => (
          <div key={n} className={`sf-flowstep${i === 2 && open.length ? ' sf-on' : ''}`}>
            <span className="sf-caption">{n}</span>
            <span className="sf-strong">{t}</span>
            <span className="sf-muted sf-small">{s}</span>
          </div>
        ))}
      </div>
      {error && <span className="sf-error" role="alert">{error}</span>}
      {open.length === 0 ? (
        <p className="sf-about">
          Nothing to review. Ask your agent to learn the rules {name} already follows: it reads the schema through the MCP
          (`describe`) and proposes them (`propose_rules`); they appear here, verified, for you to approve.
        </p>
      ) : (
        <div className="sf-row-between">
          <span className="sf-muted">{open.length} proposed · {ready.length} verified</span>
          <button type="button" className="sf-button" disabled={!ready.length}
            onClick={() => act(Promise.all(ready.map((i) => approve(name, i.proposal.id))))}>
            Approve the {ready.length} verified
          </button>
        </div>
      )}
      {open.map((i) => <ProposalCard key={i.proposal.id} item={i} act={act} />)}
      {done.length > 0 && (
        <section className="sf-col">
          <span className="sf-caption">Decided · {done.length}</span>
          {done.map(({ proposal: p }) => (
            <div key={p.id} className="sf-decided">
              <span className={`sf-status sf-status-${p.status}`}>{p.status === 'approved' ? 'Approved' : 'Rejected'}</span>
              <span className="sf-mono sf-small">#{p.id}</span>
              <span>{p.rule ? `@rule:${p.rule}` : ''} {p.why}</span>
              <span className="sf-muted sf-small">by {p.by}, {p.status} by {p.decided_by}</span>
            </div>
          ))}
        </section>
      )}
    </div>
  )
}

function ProposalCard({ item, act }: { item: Item; act: (p: Promise<unknown>) => void }) {
  const { name, ix, catalog } = useWorkbench()
  const { proposal: p, verdict: v } = item
  const [reason, setReason] = useState('')
  if (!v) return null
  const conflict = v.state === 'conflict'
  const blocked = v.state === 'invalid' || v.state === 'duplicate'
  const other = v.conflicts?.[0]
  const where = p.at.level === 'global' ? 'every schema' : scopeTitle(ix, name, p.at)
  return (
    <article className={`sf-proposal sf-proposal-${v.state}`}>
      <div className="sf-row-between">
        <span className="sf-row-gap">
          <span className="sf-caption">#{p.id} · {p.what.kind === 'new' ? 'a new rule' : p.what.kind === 'link' ? 'a rule of the catalog' : 'an exception'}</span>
          <span className="sf-muted sf-small">at <b className="sf-accent">{where}</b> · proposed by {p.by}</span>
        </span>
        <span className={`sf-status sf-state-${v.state}`}>{STATE[v.state]}</span>
      </div>
      <span className="sf-proposal-title">{v.title}</span>
      {p.what.kind === 'off' && <span className="sf-muted">Because: {p.what.reason}</span>}
      <div className="sf-proposal-grid">
        <div className="sf-col">
          <span className="sf-caption">The agent's evidence</span>
          <span>{p.why}</span>
          {p.what.kind !== 'off' && <TallyBar tally={v.tally} preview />}
        </div>
        <div className="sf-col">
          <span className="sf-caption">The system's checks</span>
          {v.notes.map((n, i) => (
            <span key={i} className="sf-note"><span className={MARK[n.mark][1]}>{MARK[n.mark][0]}</span><span>{n.text}</span></span>
          ))}
        </div>
      </div>
      {v.breaks.length > 0 && <Findings findings={v.breaks} limit={5} />}
      {conflict && other && (
        <div className="sf-conflict">
          <span className="sf-strong">The system will not take it alone: "{catalog.rules.find((r) => r.id === other)?.title}" says otherwise.</span>
          <span className="sf-muted sf-small">Approve it with that rule switched off at {where} (the reason is kept and the agent reads it), or reject it.</span>
          <input className="sf-input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder={`Why ${other} gives way here`} aria-label="Why the other rule gives way" />
        </div>
      )}
      <div className="sf-row-gap">
        {p.what.kind !== 'off' && <EnforceToggle value={p.enforce} onChange={(e) => act(proposalEnforce(name, p.id, e))} />}
        <button type="button" className="sf-button" disabled={blocked || (conflict && !reason.trim())}
          onClick={() => act(conflict && other
            ? linkRule(name, { rule: other, at: p.at, off: true, reason }).then(() => approve(name, p.id))
            : approve(name, p.id))}>
          {conflict ? `Approve, and switch ${other} off here` : 'Approve'}
        </button>
        <button type="button" className="sf-chip" onClick={() => act(reject(name, p.id))}>Reject</button>
      </div>
    </article>
  )
}
