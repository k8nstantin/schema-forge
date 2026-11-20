// SQL shown read-only, highlighted in the workbench's palette.

import { sql, PostgreSQL, StandardSQL } from '@codemirror/lang-sql'
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language'
import { EditorState } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import { tags } from '@lezer/highlight'
import { useEffect, useRef } from 'react'

import type { Target } from '../model'

const theme = EditorView.theme(
  {
    '&': { backgroundColor: 'transparent', color: '#EDE4F4', fontSize: '13px' },
    '.cm-content': { fontFamily: "'JetBrains Mono', ui-monospace, monospace", padding: '14px 0' },
    '.cm-gutters': { display: 'none' },
    '&.cm-focused': { outline: 'none' },
  },
  { dark: true },
)

const colours = HighlightStyle.define([
  { tag: tags.keyword, color: '#CC66FF' },
  { tag: [tags.string, tags.special(tags.string)], color: '#B8A6CC' },
  { tag: tags.number, color: '#F5C26B' },
  { tag: [tags.typeName, tags.standard(tags.name)], color: '#8FB8FF' },
  { tag: tags.comment, color: '#8F7BA5', fontStyle: 'italic' },
  { tag: tags.special(tags.name), color: '#A9C8FF' },
])

export function Sql({ text, target }: { text: string; target: Target }) {
  const host = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!host.current) return
    const view = new EditorView({
      parent: host.current,
      state: EditorState.create({
        doc: text,
        extensions: [
          sql({ dialect: target === 'postgres' ? PostgreSQL : StandardSQL }),
          syntaxHighlighting(colours),
          theme,
          EditorState.readOnly.of(true),
          EditorView.lineWrapping,
        ],
      }),
    })
    return () => view.destroy()
  }, [text, target])
  return <div ref={host} className="sf-sql" />
}
