// Laying out the diagram with ELK: tables and views inside their namespaces; layered where relationships
// connect them, packed where they do not (an Iceberg schema without logical relationships yet). Every column has
// a port on each side of its card, and ELK routes each edge between ports around the cards, so the diagram draws
// the routes ELK found rather than lines that cross what lies between their ends.

import ELK, { type ElkExtendedEdge, type ElkNode, type ElkPort } from 'elkjs/lib/elk.bundled.js'
import type { Edge, Node, XYPosition } from '@xyflow/react'

import type { Schema } from '../model'
import { CARD_WIDTH, HEAD_PORT, columnPort, tableHeight, viewHeight } from './geometry'

const elk = new ELK()

/// The handle id an edge meets on a card: a column's, or the relation's own in the header.
const headIn = 'relation:in'
const headOut = 'relation:out'
/// Port ids are global in ELK, so each carries its card's id; a column id already is global.
const port = (node: string, handle: string) => (handle.startsWith('relation:') ? `${node}/${handle}` : handle)
/// A port on a card's left (in) or right (out) side, `y` from its top. The side is stated, since not every
/// algorithm infers it from the position.
const side = (id: string, out: boolean, y: number): ElkPort => ({
  id,
  x: out ? CARD_WIDTH : 0,
  y,
  width: 0,
  height: 0,
  layoutOptions: { 'elk.port.side': out ? 'EAST' : 'WEST' },
})

export interface Routed {
  /// The route ELK found, in the diagram's coordinates, from the source handle to the target handle.
  route?: XYPosition[]
}

export async function layout(model: Schema, unfolded: Set<string>): Promise<{ nodes: Node[]; edges: Edge[] }> {
  const tables = model.tables ?? []
  const views = model.views ?? []
  const relations = [...tables.map((t) => ({ id: t.id, ns: t.namespace, kind: 'table' as const })),
    ...views.map((v) => ({ id: v.id, ns: v.namespace, kind: 'view' as const }))]
  // Every edge runs from what is referenced, read or partitioned to what references, reads or partitions it, so
  // parents sit to the left of their children.
  const edges: (Edge & { data: Routed })[] = [
    ...(model.relationships ?? [])
      .filter((r) => r.from.table !== r.to.table)
      .map((r) => ({
        id: r.id,
        type: 'relation',
        source: r.to.table,
        sourceHandle: `${r.to.columns[0]}:out`,
        target: r.from.table,
        targetHandle: `${r.from.columns[0]}:in`,
        data: { relationship: r },
      })),
    ...views.flatMap((v) =>
      (v.reads ?? []).map((read) => ({
        id: `${v.id}<-${read}`,
        type: 'reads',
        source: read,
        sourceHandle: headOut,
        target: v.id,
        targetHandle: headIn,
        data: {},
      })),
    ),
    ...tables.flatMap((t) =>
      t.partition_of
        ? [{
            id: `${t.id}~${t.partition_of.parent}`,
            type: 'partition',
            source: t.partition_of.parent,
            sourceHandle: headOut,
            target: t.id,
            targetHandle: headIn,
            data: {},
          }]
        : [],
    ),
  ]
  const algorithm = edges.length > 0 ? 'layered' : 'rectpacking'
  // Namespaces that hold something, innermost ones being where tables live.
  const holding = new Set(relations.map((r) => r.ns))
  const namespaces = (model.namespaces ?? []).filter((n) => holding.has(n.id))

  const card = (r: (typeof relations)[number]): ElkNode => {
    const ports: ElkPort[] = [side(port(r.id, headIn), false, HEAD_PORT), side(port(r.id, headOut), true, HEAD_PORT)]
    let height: number
    if (r.kind === 'table') {
      const t = tables.find((x) => x.id === r.id)!
      height = tableHeight(t, unfolded)
      t.columns.forEach((c, i) => {
        const y = columnPort(t, i, unfolded)
        ports.push(side(`${c.id}:in`, false, y), side(`${c.id}:out`, true, y))
      })
    } else {
      height = viewHeight(model, r.id)
    }
    return { id: r.id, width: CARD_WIDTH, height, ports, layoutOptions: { 'elk.portConstraints': 'FIXED_POS' } }
  }

  // Room between columns of cards for the crow's feet at both ends of an edge and the bends between them.
  const spacing = {
    'elk.algorithm': algorithm,
    'elk.direction': 'RIGHT',
    'elk.edgeRouting': 'ORTHOGONAL',
    'elk.spacing.edgeNode': '24',
    'elk.spacing.edgeEdge': '12',
    'elk.layered.spacing.nodeNodeBetweenLayers': '96',
    'elk.layered.spacing.edgeNodeBetweenLayers': '32',
    'elk.aspectRatio': '1.6',
  }
  const graph: ElkNode = {
    id: 'root',
    layoutOptions: {
      ...spacing,
      'elk.hierarchyHandling': 'INCLUDE_CHILDREN',
      'elk.spacing.nodeNode': '48',
      // Edge points in the diagram's coordinates, whichever namespace an edge crosses.
      'elk.json.edgeCoords': 'ROOT',
    },
    children: namespaces.map((n) => ({
      id: n.id,
      layoutOptions: {
        ...spacing,
        'elk.padding': '[top=56,left=28,bottom=28,right=28]',
        'elk.spacing.nodeNode': '40',
      },
      children: relations.filter((r) => r.ns === n.id).map(card),
    })),
    edges: edges.map((e) => ({
      id: e.id,
      sources: [port(e.source, e.sourceHandle!)],
      targets: [port(e.target, e.targetHandle!)],
    })),
  }
  const laid = await elk.layout(graph)

  const nodes: Node[] = []
  for (const group of laid.children ?? []) {
    nodes.push({
      id: group.id,
      type: 'namespace',
      position: { x: group.x ?? 0, y: group.y ?? 0 },
      data: { label: namespaces.find((n) => n.id === group.id)?.name ?? '' },
      style: { width: group.width, height: group.height },
      selectable: false,
      draggable: false,
    })
    for (const child of group.children ?? []) {
      nodes.push({
        id: child.id,
        type: relations.find((x) => x.id === child.id)!.kind,
        parentId: group.id,
        extent: 'parent',
        position: { x: child.x ?? 0, y: child.y ?? 0 },
        data: {},
        // Set on the node, a size is both its style and what the card reads from its props.
        width: CARD_WIDTH,
        height: child.height,
      })
    }
  }
  const routes = new Map((laid.edges ?? []).map((e: ElkExtendedEdge) => [e.id, e.sections?.[0]]))
  for (const e of edges) {
    const s = routes.get(e.id)
    if (s) e.data.route = [s.startPoint, ...(s.bendPoints ?? []), s.endPoint]
  }
  return { nodes, edges }
}
