// The diagram perspective: tables and views as cards in their namespaces, relationships drawn as they are.

import {
  Background,
  BaseEdge,
  Controls,
  MiniMap,
  ReactFlow,
  getSmoothStepPath,
  useEdgesState,
  useNodesState,
  type EdgeProps,
  type XYPosition,
} from '@xyflow/react'
import '@xyflow/react/dist/style.css'
import { Text } from '@mantine/core'
import { useEffect, useMemo, useState } from 'react'

import type { Relationship } from '../model'
import { useIndex, useWorkbench } from '../state'
import { Folding, NamespaceGroup, TableCard, ViewCard } from './cards'
import { layout, type Routed } from './layout'

const nodeTypes = { table: TableCard, view: ViewCard, namespace: NamespaceGroup }
const edgeTypes = { relation: RelationEdge, reads: ReadsEdge, partition: PartitionEdge }

export function Diagram() {
  const { model, select } = useWorkbench()
  const [nodes, setNodes, onNodesChange] = useNodesState<never>([])
  const [edges, setEdges, onEdgesChange] = useEdgesState<never>([])
  const [unfolded, setUnfolded] = useState<Set<string>>(new Set())
  const [failed, setFailed] = useState<string | null>(null)
  const folding = useMemo(
    () => ({
      unfolded,
      toggle: (id: string) =>
        setUnfolded((u) => {
          const next = new Set(u)
          if (next.has(id)) next.delete(id)
          else next.add(id)
          return next
        }),
    }),
    [unfolded],
  )
  useEffect(() => {
    let live = true
    layout(model, unfolded).then(
      (l) => {
        if (live) {
          setNodes(l.nodes as never[])
          setEdges(l.edges as never[])
          setFailed(null)
        }
      },
      (e) => live && setFailed(String(e?.message ?? e)),
    )
    return () => {
      live = false
    }
  }, [model, unfolded, setNodes, setEdges])
  if (failed) {
    return (
      <Text c="red" p="lg">
        The diagram could not be laid out: {failed}
      </Text>
    )
  }
  return (
    <Folding.Provider value={folding}>
      <Markers />
      <ReactFlow
        nodes={nodes}
        edges={edges}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        nodeTypes={nodeTypes}
        edgeTypes={edgeTypes}
        onPaneClick={() => select(null)}
        fitView
        minZoom={0.05}
        maxZoom={2}
        proOptions={{ hideAttribution: true }}
        nodesConnectable={false}
        colorMode="dark"
      >
        <Background gap={24} size={1} color="#3B2449" />
        <MiniMap pannable zoomable nodeColor={(n) => (n.type === 'namespace' ? 'transparent' : '#9500BF')} maskColor="rgba(14,2,22,0.7)" />
        <Controls showInteractive={false} />
      </ReactFlow>
    </Folding.Provider>
  )
}

/// Crow's feet: `one` where the edge leaves the referenced table, `many` where it meets the referencing one (a ring
/// before it when the column can be null). Each marker's +x points into its card, so the feet open onto the card.
function Markers() {
  return (
    <svg style={{ position: 'absolute', width: 0, height: 0 }} aria-hidden>
      <defs>
        <marker id="sf-many" viewBox="0 0 20 20" refX="18" refY="10" markerWidth="18" markerHeight="18" orient="auto-start-reverse">
          <path d="M2 10 L18 2 M2 10 L18 10 M2 10 L18 18" stroke="#CC66FF" strokeWidth="1.6" fill="none" />
        </marker>
        <marker id="sf-many-optional" viewBox="0 0 30 20" refX="28" refY="10" markerWidth="26" markerHeight="18" orient="auto-start-reverse">
          <path d="M16 10 L28 3 M16 10 L28 10 M16 10 L28 17" stroke="#CC66FF" strokeWidth="1.6" fill="none" />
          <circle cx="8" cy="10" r="4.5" stroke="#CC66FF" strokeWidth="1.6" fill="#150420" />
        </marker>
        <marker id="sf-one" viewBox="0 0 20 20" refX="18" refY="10" markerWidth="18" markerHeight="18" orient="auto-start-reverse">
          <path d="M12 3 L12 17 M16 3 L16 17" stroke="#CC66FF" strokeWidth="1.6" fill="none" />
        </marker>
      </defs>
    </svg>
  )
}

function RelationEdge(props: EdgeProps) {
  const ix = useIndex()
  const { selection } = useWorkbench()
  const r = (props.data as { relationship: Relationship }).relationship
  const path = routedPath(props)
  const optional = r.from.columns.some((c) => ix.columns.get(c)?.column.nullable)
  const touched =
    selection &&
    (selection.id === r.from.table || selection.id === r.to.table || r.from.columns.includes(selection.id) || r.to.columns.includes(selection.id))
  return (
    <BaseEdge
      id={props.id}
      path={path}
      markerStart="url(#sf-one)"
      markerEnd={`url(#${optional ? 'sf-many-optional' : 'sf-many'})`}
      style={{
        stroke: touched ? '#F6E8FF' : '#B833E8',
        strokeWidth: touched ? 2.2 : 1.5,
        strokeDasharray: r.enforced ? undefined : '6 5',
      }}
    />
  )
}

function ReadsEdge(props: EdgeProps) {
  const path = routedPath(props)
  return <BaseEdge id={props.id} path={path} style={{ stroke: '#5C4470', strokeWidth: 1.2, strokeDasharray: '2 4' }} />
}

/// A partition hangs off its parent table.
function PartitionEdge(props: EdgeProps) {
  const path = routedPath(props)
  return <BaseEdge id={props.id} path={path} style={{ stroke: '#8300A8', strokeWidth: 1.2, strokeDasharray: '1 3' }} />
}

/// The route ELK found around the cards, its corners rounded; a step path instead once a card has been dragged off
/// the ends of its route.
function routedPath(props: EdgeProps): string {
  const route = (props.data as Routed | undefined)?.route
  const first = route?.[0]
  const last = route?.[route.length - 1]
  const near = (a: XYPosition, x: number, y: number) => Math.abs(a.x - x) <= 8 && Math.abs(a.y - y) <= 2
  if (!route || !first || !last || !near(first, props.sourceX, props.sourceY) || !near(last, props.targetX, props.targetY)) {
    return getSmoothStepPath({ ...props, borderRadius: 10 })[0]
  }
  // The handle sits half its width outside the card: start and end exactly on it.
  const points = [{ x: props.sourceX, y: first.y }, ...route.slice(1, -1), { x: props.targetX, y: last.y }]
  return rounded(points, 10)
}

/// An orthogonal polyline with each corner cut by a quarter circle of up to `radius`.
function rounded(points: XYPosition[], radius: number): string {
  let d = `M ${points[0].x} ${points[0].y}`
  for (let i = 1; i < points.length - 1; i++) {
    const [a, b, c] = [points[i - 1], points[i], points[i + 1]]
    const r = Math.min(radius, Math.hypot(b.x - a.x, b.y - a.y) / 2, Math.hypot(c.x - b.x, c.y - b.y) / 2)
    const toward = (p: XYPosition) => {
      const len = Math.hypot(p.x - b.x, p.y - b.y) || 1
      return { x: b.x + ((p.x - b.x) / len) * r, y: b.y + ((p.y - b.y) / len) * r }
    }
    const [p, q] = [toward(a), toward(c)]
    d += ` L ${p.x} ${p.y} Q ${b.x} ${b.y} ${q.x} ${q.y}`
  }
  const end = points[points.length - 1]
  return `${d} L ${end.x} ${end.y}`
}
