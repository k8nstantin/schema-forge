// The Rules perspective: the rules as a diagram (a level, or one rule), the catalog, goals, and groups.
// Its place in the address: `level:<level>`, `rule:<id>`, `catalog:<id>`, `goals:<id>`, `groups`.

import { useWorkbench } from '../state'
import { BreaksView } from './BreaksView'
import { CatalogView } from './CatalogView'
import { LevelDiagram, RuleDiagram } from './Diagram'
import { GoalsView } from './GoalsView'
import { GroupsView } from './GroupsView'
import { ReviewView } from './ReviewView'
import { parseScope } from './scope'

const VIEWS = [
  ['level', 'Diagram'],
  ['breaks', 'What breaks'],
  ['review', 'Review'],
  ['catalog', 'Catalog'],
  ['goals', 'Goals'],
  ['groups', 'Groups'],
] as const

export function RulesView({ arg }: { arg?: string }) {
  const { go, rules } = useWorkbench()
  const colon = arg?.indexOf(':') ?? -1
  const view = !arg ? 'level' : colon < 0 ? arg : arg.slice(0, colon)
  const rest = colon < 0 ? undefined : arg!.slice(colon + 1)
  const tab = view === 'rule' ? 'level' : view
  return (
    <div className="sf-col">
      <div className="sf-subnav">
        <nav className="sf-tabs" role="tablist" aria-label="Rules views">
          {VIEWS.map(([v, label]) => (
            <button key={v} type="button" role="tab" aria-selected={tab === v} onClick={() => go('rules', v === 'level' ? undefined : v)}>{label}</button>
          ))}
        </nav>
        {rules.report.problems.length > 0 && <span className="sf-error">{rules.report.problems.join(' · ')}</span>}
      </div>
      {view === 'level' && <div className="sf-page"><LevelDiagram scope={parseScope(rest)} /></div>}
      {view === 'rule' && rest && <div className="sf-page"><RuleDiagram id={rest} /></div>}
      {view === 'catalog' && <CatalogView selected={rest} />}
      {view === 'goals' && <GoalsView selected={rest} />}
      {view === 'groups' && <GroupsView />}
      {view === 'breaks' && <BreaksView />}
      {view === 'review' && <ReviewView />}
    </div>
  )
}
