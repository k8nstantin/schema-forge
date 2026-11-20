// The definition perspective: the selected object's SQL, exactly as Schema Forge writes it for the target.

import { sql, PostgreSQL, StandardSQL } from '@codemirror/lang-sql'
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language'
import { EditorState } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import { tags } from '@lezer/highlight'
import { Text } from '@mantine/core'
import { useEffect, useRef, useState } from 'react'

import { definition } from '../api'
import { useWorkbench } from '../state'

const theme = EditorView.theme(
  {
    '&': { backgroundColor: 'transparent', color: '#EDE4F4', fontSize: '13px', height: '100%' },
    '.cm-content': { fontFamily: "'JetBrains Mono', ui-monospace, monospace", padding: '12px 0' },
    '.cm-gutters': { display: 'none' },
    '&.cm-focused': { outline: 'none' },
  },
  { dark: true },
)

const colours = HighlightStyle.define([
  { tag: tags.keyword, color: '#CC66FF' },
  { tag: [tags.string, tags.special(tags.string)], color: '#7EE0B5' },
  { tag: tags.number, color: '#F5C26B' },
  { tag: [tags.typeName, tags.standard(tags.name)], color: '#8FB8FF' },
  { tag: tags.comment, color: '#8F7BA5', fontStyle: 'italic' },
  { tag: tags.special(tags.name), color: '#DDA9FF' },
])

export function Definition() {
  const { name, model, selection } = useWorkbench()
  const [text, setText] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const host = useRef<HTMLDivElement>(null)
  const id = selection ? (selection.kind === 'column' ? selection.table : selection.id) : null
  useEffect(() => {
    setError(null)
    if (!id) {
      setText(null)
      return
    }
    definition(name, id).then(setText, (e) => setError(String(e.message ?? e)))
  }, [name, id, model])
  useEffect(() => {
    if (!host.current || text === null) return
    const view = new EditorView({
      parent: host.current,
      state: EditorState.create({
        doc: text,
        extensions: [
          sql({ dialect: model.target === 'postgres' ? PostgreSQL : StandardSQL }),
          syntaxHighlighting(colours),
          theme,
          EditorState.readOnly.of(true),
          EditorView.lineWrapping,
        ],
      }),
    })
    return () => view.destroy()
  }, [text, model.target])
  if (!id) return <Text c="dimmed" p="lg">Select a table or a view to see its SQL.</Text>
  if (error) return <Text c="red" p="lg">{error}</Text>
  return <div ref={host} className="sf-perspective-pad sf-code" />
}
